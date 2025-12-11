# Script creates Storage Space in Simple mode: HDD + SSD cache (validate via: Get-VirtualDisk | Get-StorageTier )
# Combined what's available on the internet then used an System.Array to pass data into the StorageTiers parameter.
# Used a different method to trim the StorageTierSupportedSize
# Used LogicalSectorSizeDefault 4kb on the creation of the Storage Pool
# Defaults to a REFS 64k volume with integrity streams enabled, this is not for everyone
# The script assumes the poolable disks that a smaller disk is the SSD cache and larger disk is the HDD

# Information pieced together from the following links
# https://nils.schimmelmann.us/post/153541254987/intel-smart-response-technology-vs-windows-10
# http://joe.blog.freemansoft.com/2020/04/accelerate-storage-spaces-with-ssds-in.html
# https://www.reddit.com/r/DataHoarder/comments/c8tucj/my_experience_with_storage_spaces_after_3_years/
# https://www.dell.com/support/manuals/en-us/storage-md1420-dsms/smssbpgpub-v1/storage-tiers?guid=guid-6aa17a7f-9282-4ed0-a5d8-ba5e9d41b9f2&lang=en-us

# Troubleshooting section, reset config, offers no confirmation, use at your own risk
# Get-VirtualDisk -FriendlyName $TieredSpaceName | Remove-VirtualDisk -Confirm:$false
# Get-StoragePool $PoolName | Remove-StoragePool -Confirm:$false
# Get-StorageTier  $SSDTierName | Remove-StorageTier -Confirm:$false
# Get-StorageTier  $HDDTierName | Remove-StorageTier -Confirm:$false

# Name your Storage Pool
$PoolName = 'StoragePool'

# Storage Spaces Type
$ResiliencySetting = 'Simple'

# Name the Storage Tiers
$SSDTierName = 'SSDTier'
$HDDTierName = 'HDDTier'

# Name your Volume
$TieredSpaceName = 'StorageSpace'

# Get Poolable Disks, use Reset-PhysicalDisk if a disk isn't showing CanPool
$PhysicalDisks = (Get-PhysicalDisk -CanPool $True)
if ($PhysicalDisks.Count -lt 2) { Write-Error "Not enough disks found!"; return }

# Get the Storage Sub System Friendly Name
$SubSysName = (Get-StorageSubSystem).FriendlyName

# Create Storage Pool
New-StoragePool -FriendlyName $PoolName -StorageSubSystemFriendlyName $SubSysName -PhysicalDisks $PhysicalDisks -LogicalSectorSizeDefault 4096

# Create Storage Tiers for Storage Pool
$SSDtier = Get-StoragePool $PoolName | New-StorageTier -FriendlyName $SSDTierName -MediaType SSD -ResiliencySettingName $ResiliencySetting
$HDDtier = Get-StoragePool $PoolName | New-StorageTier -FriendlyName $HDDTierName -MediaType HDD -ResiliencySettingName $ResiliencySetting

# Get the Storage Tier Max Size
$SSDTierSize = (Get-StorageTierSupportedSize -FriendlyName $SSDTierName -ResiliencySettingName $ResiliencySetting).TierSizeMax
$HDDTierSize = (Get-StorageTierSupportedSize -FriendlyName $HDDTierName -ResiliencySettingName $ResiliencySetting).TierSizeMax 
# Trim 4gb to fit into New-VirtualDisk StorageTierSizes.  I see reports you may have to use more.  If you have errors in the New-VirtualDisk start trimming more.
$SSDTierSize = ($SSDTierSize -= 4GB)
$HDDTierSize = ($HDDTierSize -= 4GB)

# You could use New-Volume instead of the next two steps but it doesn't have enough control

# Create the Virtual Disk
# AI Says: -WriteCacheSize 0: Disables the 1GB RAM buffer so writes hit SSD Tier directly.
# AI Says: -ProvisioningType Fixed: REQUIRED for Tiering to map hot/cold blocks correctly.
New-VirtualDisk -StoragePoolFriendlyName $PoolName -FriendlyName $TieredSpaceName -StorageTiers $SSDtier, $HDDtier -StorageTierSizes $SSDTierSize, $HDDTierSize -ProvisioningType Fixed -WriteCacheSize 0

# Create the Useable Volume 
Get-VirtualDisk  $TieredSpaceName | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem refs  -SetIntegrityStreams $false -NewFileSystemLabel $TieredSpaceName -AllocationUnitSize 65536 
