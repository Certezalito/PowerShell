# Script creates Storage Space in Simple mode: HDD + SSD cache
# Combined what's available on the internet then used an System.Array to pass data into the StorageTiers parameter.
# Used a different method to trim the StorageTierSupportedSize
# Used LogicalSectorSizeDefault 4kb on the creation of the Storage Pool
# Defaults to a REFS 64k volume with integrity streams enabled, this is not for everyone
# The script assumes the poolable disks that a smaller disk is the SSD cache and larger disk is the HDD

# Information pieced together from the following links
# https://nils.schimmelmann.us/post/153541254987/intel-smart-response-technology-vs-windows-10
# http://joe.blog.freemansoft.com/2020/04/accelerate-storage-spaces-with-ssds-in.html
# https://www.reddit.com/r/DataHoarder/comments/c8tucj/my_experience_with_storage_spaces_after_3_years/

# Troubleshooting section, reset config, offers no confirmation, use at your own risk
# Get-VirtualDisk -FriendlyName $TieredSpaceName | Remove-VirtualDisk -Confirm:$false
# Get-StoragePool $PoolName | Remove-StoragePool -Confirm:$false
# Get-StorageTier  $SSDTierName | Remove-StorageTier -Confirm:$false
# Get-StorageTier  $HDDTierName | Remove-StorageTier -Confirm:$false

# Name your Storage Pool
$PoolName = 'WetInPool'

# Storage Spaces Type
$ResiliencySetting = 'Simple'

# Name the Storage Tiers
$SSDTierName = 'SSDTier'
$HDDTierName = 'HDDTier'

# Name your Virtual Disk / Disk / Volume
$TieredSpaceName = 'StorageSpace'

# Get Poolable Disks, use Reset-PhysicalDisk if a disk isn't showing CanPool
$PhysicalDisks = (Get-PhysicalDisk -CanPool $True)

# Get the Storage Sub System Friendly Name
$SubSysName = (Get-StorageSubSystem).FriendlyName


# Create Storage Pool
New-StoragePool -FriendlyName $PoolName -StorageSubSystemFriendlyName $SubSysName -PhysicalDisks $PhysicalDisks -LogicalSectorSizeDefault 4kb

# Create Storage Tiers for Storage Pool
Get-StoragePool $PoolName | New-StorageTier -FriendlyName $SSDTierName -MediaType SSD -ResiliencySettingName $ResiliencySetting
Get-StoragePool $PoolName | New-StorageTier -FriendlyName $HDDTierName -MediaType HDD -ResiliencySettingName $ResiliencySetting

# StorageTiers prefers pstype as System.Array, sorting by size to put smaller SSDs first in the array
$storagetier = (Get-StorageTier | Sort-Object size)

# Get the Storage Tier Max Size
$SSDTierSize = (Get-StorageTierSupportedSize -FriendlyName $SSDTierName -ResiliencySettingName $ResiliencySetting).TierSizeMax
$HDDTierSize = (Get-StorageTierSupportedSize -FriendlyName $HDDTierName -ResiliencySettingName $ResiliencySetting).TierSizeMax 
# Trim 2gb to fit into New-VirtualDisk StorageTierSizes.  I see reports you may have to use 4gb or more.  If you have errors in the New-VirtualDisk start trimming here.
$SSDTierSize = ($SSDTierSize -= 2000000000)
$HDDTierSize = ($HDDTierSize -= 2000000000)

# Create the Virtual Disk
New-VirtualDisk -StoragePoolFriendlyName $PoolName -FriendlyName $TieredSpaceName -StorageTiers @($storagetier[0],$storagetier[1]) -StorageTierSizes @($SSDTierSize,$HDDTierSize) -ResiliencySettingName $ResiliencySetting  -AutoWriteCacheSize 

# Create the Useable Volume 
Get-VirtualDisk  $TieredSpaceName | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem refs  -SetIntegrityStreams $false -NewFileSystemLabel $TieredSpaceName -AllocationUnitSize 65536 
