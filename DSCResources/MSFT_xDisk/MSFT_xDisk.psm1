#
# xComputer: DSC resource to initialize, partition, and format disks.
#

function Get-TargetResource
{
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [uint32] $DiskNumber,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DriveLetter,

        [UInt64] $Size,
        [string] $FSLabel,
        [UInt32] $AllocationUnitSize
    )

    $Disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    
    $Partition = Get-Partition -ErrorAction SilentlyContinue | Where-Object {$_.AccessPaths -contains $DriveLetter -or $_.DriveLetter -eq $DriveLetter}
    $PartitionGuid = ($Partition | select -ExpandProperty Guid)

    $FSLabel = $Partition | Get-Volume -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FileSystemLabel
	
    
    if ($PartitionGuid) 
    {
		$Query = [String]::Format("SELECT BlockSize from Win32_Volume WHERE DeviceID = '\\\\?\\Volume{0}\\'", $PartitionGuid)
		$BlockSize = Get-CimInstance -Query $Query -ErrorAction SilentlyContinue | select -ExpandProperty BlockSize
        
        if($BlockSize){
            $AllocationUnitSize = $BlockSize
        } 
        else 
        {
            # If Get-CimInstance did not return a value, try again with Get-WmiObject
            $BlockSize = Get-WmiObject -Query $Query -ErrorAction SilentlyContinue | select -ExpandProperty BlockSize
            $AllocationUnitSize = $BlockSize
        }
    } else {
        # The Partition doesn't exist so it can't have a block size.
		$BlockSize = $null
	}
	
    
    if ($Partition)
    {
        # In order for $Partition to not be $null, the $DriveLetter passed into the function had to exist on a partition
        # Since $DriveLetter could be either a $Partition.DriveLetter OR an entry from $Partition.AccessPaths we just pass back the $DriveLetter 
        # that was passed in so it matches what was expected.
        $AssignedDriveLetter = $DriveLetter
    }
    
    
    $returnValue = @{
        DiskNumber = $Disk.Number
        DriveLetter = $AssignedDriveLetter
        Size = $Partition.Size
        FSLabel = $FSLabel
        AllocationUnitSize = $AllocationUnitSize
    }
    $returnValue
}

function Set-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [uint32] $DiskNumber,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DriveLetter,

        [UInt64] $Size,
        [string] $FSLabel,
        [UInt32] $AllocationUnitSize
    )
    
    try
    {
        $Disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    
        if ($Disk.IsOffline -eq $true)
        {
            Write-Verbose 'Setting disk Online'
            $Disk | Set-Disk -IsOffline $false
        }
        
        if ($Disk.IsReadOnly -eq $true)
        {
            Write-Verbose 'Setting disk to not ReadOnly'
            $Disk | Set-Disk -IsReadOnly $false
        }

        Write-Verbose -Message "Checking existing disk partition style..."
        if (($Disk.PartitionStyle -ne "GPT") -and ($Disk.PartitionStyle -ne "RAW"))
        {
            Throw "Disk '$($DiskNumber)' is already initialised with '$($Disk.PartitionStyle)'"
        }
        else
        {
            if ($Disk.PartitionStyle -eq "RAW")
            {
                Write-Verbose -Message "Initializing disk number '$($DiskNumber)'..."
                $Disk | Initialize-Disk -PartitionStyle "GPT" -PassThru
            }
            else
            {
                Write-Verbose -Message "Disk number '$($DiskNumber)' is already configured for 'GPT'"
            }
        }

        # Check if existing partition already has file system on it
        
        if (($Disk | Get-Partition | Get-Volume ) -eq $null)
        {


            Write-Verbose -Message "Creating the partition..."
            $PartParams = @{
                            DiskNumber = $DiskNumber
                            }
            if ($DriveLetter.Length -eq 1) {
                Write-Verbose "Creating partition with Drive Letter '$($DriveLetter)'"
                $PartParams["DriveLetter"] = $DriveLetter
            } else {
                Write-Verbose "Creating partition on Mount Point '$($DriveLetter)'" 
                $PartParams["DiskPath"] = $DriveLetter
            }
            
            
            if ($Size)
            {
                $PartParams["Size"] = $Size
            }
            else
            {
                $PartParams["UseMaximumSize"] = $true
            }

            $Partition = New-Partition @PartParams
            
            # Sometimes the disk will still be read-only after the call to New-Partition returns.
            Start-Sleep -Seconds 5

            Write-Verbose -Message "Formatting the volume..."
            $VolParams = @{
                        FileSystem = "NTFS";
                        Confirm = $false
                        }

            if ($FSLabel)
            {
                $VolParams["NewFileSystemLabel"] = $FSLabel
            }
            if($AllocationUnitSize)
            {
                $VolParams["AllocationUnitSize"] = $AllocationUnitSize 
            }

            $Volume = $Partition | Format-Volume @VolParams


            if ($Volume)
            {
                Write-Verbose -Message "Successfully initialized '$($DriveLetter)'."
            }
        }
        else 
        {
            Write-Verbose -Message "The volume already exists, adjusting drive letter..."
            if ($DriveLetter.Length -eq 1) {
                Write-Verbose "Changing Drive Letter to '$($DriveLetter)'"
                $VolumeDriveLetter = ($Disk | Get-Partition | Get-Volume).driveletter
                Set-Partition -DriveLetter $VolumeDriveLetter -NewDriveLetter $DriveLetter
            } else {
                Write-Verbose "Removing all existing Mount Points (Access Paths)..."
                $Partition = $Disk | Get-Partition | Where-Object {$_.AccessPaths -contains $DriveLetter}
                $AccessPaths = $Partition | Select-Object -ExpandProperty AccessPaths | Where-Object {$_ -notlike '\\?\Volume{*'}
                
                $AccessPaths | Foreach-Object {
                    Write-Verbose "Remove Access Path '$($_)' on Disk '$($Disk.Number)', Partition '$($Partition.PartitionNumber)'..."
                    Remove-PartitionAccessPath -DiskNumber $Disk.Number -PartitionNumber $Partition.PartitionNumber -AccessPath $_
                }
                
                Write-Verbose "Adding Access Path '$($DriveLetter)' on Disk '$($Disk.Number)', Partition '$($Partition.PartitionNumber)'..."
                Add-PartitionAccessPath -DiskNumber $Disk.Number -PartitionNumber $Partition.PartitionNumber -AccessPath $DriveLetter
            }
            
        }
    }    
    catch
    {
        $message = $_.Exception.Message
        Throw "Disk Set-TargetResource failed with the following error: '$($message)'"
    }
}

function Test-TargetResource
{
    [OutputType([System.Boolean])]
    [cmdletbinding()]
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [uint32] $DiskNumber,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DriveLetter,

        [UInt64] $Size,
        [string] $FSLabel,
        [UInt32] $AllocationUnitSize
    )

    Write-Verbose -Message "Checking if disk number '$($DiskNumber)' is initialized..."
    $Disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue

    if (-not $Disk)
    {
        Write-Verbose "Disk number '$($DiskNumber)' was not found."
        return $false
    }

    if ($Disk.IsOffline -eq $true)
    {
        Write-Verbose 'Disk is not Online'
        return $false
    }
    
    if ($Disk.IsReadOnly -eq $true)
    {
        Write-Verbose 'Disk set as ReadOnly'
        return $false
    }

    if ($Disk.PartitionStyle -ne "GPT")
    {
        Write-Verbose "Disk '$($DiskNumber)' is initialised with '$($Disk.PartitionStyle)' partition style"
        return $false
    }

    $Partition = Get-Partition -ErrorAction SilentlyContinue | Where-Object {$_.AccessPaths -contains $DriveLetter -or $_.DriveLetter -eq $DriveLetter}
    $PartitionGuid = ($Partition | select -ExpandProperty Guid)
    if (-not $Partition)
    {
        Write-Verbose "Drive or Mount Point $DriveLetter was not found"
        return $false
    }

    # Drive size
    if ($Size)
    {
        if ($Partition.Size -ne $Size)
        {
            Write-Verbose "Drive $DriveLetter size does not match expected value. Current: $($Partition.Size) Expected: $Size"
            return $false
        }
    }

    if ($PartitionGuid)
    {
        $Query = [String]::Format("SELECT BlockSize from Win32_Volume WHERE DeviceID = '\\\\?\\Volume{0}\\'", $PartitionGuid)
        $BlockSize = Get-CimInstance -Query $Query -ErrorAction SilentlyContinue  | select -ExpandProperty BlockSize
        if (-not($BlockSize)){
            # If Get-CimInstance did not return a value, try again with Get-WmiObject
            $BlockSize = Get-WmiObject -Query $Query -ErrorAction SilentlyContinue  | select -ExpandProperty BlockSize
        }

        if($BlockSize -gt 0 -and $AllocationUnitSize -ne 0)
        {
            if($AllocationUnitSize -ne $BlockSize)
            {
                # Just write a warning, we will not try to reformat a drive due to invalid allocation unit sizes
                Write-Verbose "Drive $DriveLetter allocation unit size does not match expected value. Current: $($BlockSize.BlockSize/1kb)kb Expected: $($AllocationUnitSize/1kb)kb"
            }    
        }
    }
    

    # Volume label
    if (-not [string]::IsNullOrEmpty($FSLabel))
    {
        $Label = $Partition | Get-Volume -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FileSystemLabel
        if ($Label -ne $FSLabel)
        {
            Write-Verbose "Volume $DriveLetter label does not match expected value. Current: $Label Expected: $FSLabel)"
            return $false
        }
    }

    return $true
}


Export-ModuleMember -Function *-TargetResource
