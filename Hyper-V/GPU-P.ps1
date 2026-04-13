# Script to setup a Virtual Machine Guest with an AMD, Nvidia, or Intel GPU-P Adapter
# Script will copy driver files to Guest Virtual Machine, rerun script when driver updates
# Script will disable checkpoints
# Assumptions: There is one GPU to Partition, either AMD, Nvidia, or Intel, script is running as admin, you connect to machine as basic session, dynamic memory is disabled
# Requirements: Credentials for Guest Virtual Machine to copy the Host Driver Files to the Guest Virtual Machine 

# Reference
# https://www.reddit.com/r/sysadmin/comments/jym8xz/gpu_partitioning_is_finally_possible_in_hyperv/
# https://forum.cfx.re/t/running-fivem-in-a-hyper-v-vm-with-full-gpu-performance-for-testing-gpu-partitioning/1281205
# https://forum.level1techs.com/t/2-gamers-1-gpu-with-hyper-v-gpu-p-gpu-partitioning-finally-made-possible-with-hyperv/172234/12
# https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/powershell-direct#copy-files-with-new-pssession-and-copy-item
# https://docs.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda#configure-the-vm-for-dda
# https://forum.level1techs.com/t/2-gamers-1-gpu-with-hyper-v-gpu-p-gpu-partitioning-finally-made-possible-with-hyperv/172234/267

# Fill out these variables for the guest virtual machine
$vm = ""
$user = ""
$password = "" 
# Optional: set to a PCI token such as DEV_7D67 to force a specific partitionable device
$preferredGpuIdToken = ""
# Optional: set to a PCI token such as DEV_AD1D to force a specific NPU/non-display partitionable device
$preferredNpuIdToken = ""
# Optional: provision a second non-display partitionable device (for example Intel NPU)
$enableNpuProvisioning = $false
# Optional: apply guest RDP stability policy workaround (recommended for Intel GPU-P)
$applyIntelRdpWorkaround = $true
# Optional: faster package transfer via zip archive over PowerShell Direct
$useArchiveTransfer = $true

function Get-PciInstanceIdFromPartitionableName
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$PartitionableName
    )

    # Example input:
    # \\?\PCI#VEN_8086&DEV_AD1D...#{GUID}\GPUPARAV
    $trimmed = $PartitionableName -replace '^\\\\\?\\', ''
    $trimmed = $trimmed -replace '#\{.*$', ''
    return ($trimmed -replace '#', '\')
}

function Copy-DriverPackageToGuest
{
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)]
        [string]$SourceFolder,
        [Parameter(Mandatory = $true)]
        [string]$GuestDriverStoreRoot,
        [Parameter(Mandatory = $true)]
        [bool]$UseArchiveTransfer
    )

    $resolvedSourceFolder = (Resolve-Path -Path $SourceFolder).Path
    $packageFolderName = Split-Path -Path ($resolvedSourceFolder.TrimEnd('\')) -Leaf

    $destinationAlreadyExists = Invoke-Command -Session $Session -ScriptBlock {
        param($driverStoreRoot, $folderName)
        $destinationFolder = Join-Path $driverStoreRoot $folderName
        Test-Path -Path $destinationFolder
    } -ArgumentList $GuestDriverStoreRoot, $packageFolderName

    if ($destinationAlreadyExists)
    {
        Write-Host "Driver package already exists in guest HostDriverStore, skipping copy:" $packageFolderName
        return
    }

    if ($UseArchiveTransfer)
    {
        $hostTempZip = Join-Path $env:TEMP ($packageFolderName + '.zip')
        $guestTempDir = 'C:\Windows\Temp\GpuPDriverCopy'
        $guestTempZip = $guestTempDir + '\\' + $packageFolderName + '.zip'

        if (Test-Path $hostTempZip)
        {
            Remove-Item -Path $hostTempZip -Force -ErrorAction SilentlyContinue
        }

        Compress-Archive -Path ($resolvedSourceFolder + '\\*') -DestinationPath $hostTempZip -CompressionLevel Fastest -Force

        Invoke-Command -Session $Session -ScriptBlock {
            param($tempDir)
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        } -ArgumentList $guestTempDir

        Copy-Item -ToSession $Session -Path $hostTempZip -Destination $guestTempZip -Force

        Invoke-Command -Session $Session -ScriptBlock {
            param($tempZip, $driverStoreRoot, $folderName)
            $destinationFolder = Join-Path $driverStoreRoot $folderName
            New-Item -Path $destinationFolder -ItemType Directory -Force | Out-Null
            Expand-Archive -Path $tempZip -DestinationPath $destinationFolder -Force
            Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
        } -ArgumentList $guestTempZip, $GuestDriverStoreRoot, $packageFolderName

        Remove-Item -Path $hostTempZip -Force -ErrorAction SilentlyContinue
    }
    else
    {
        Copy-Item -ToSession $Session -Path ($resolvedSourceFolder + '\\') -Destination $GuestDriverStoreRoot -Recurse -Force
    }
}

function Resolve-DriverStoreFolderFromPublishedInf
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$PublishedInfName,
        [Parameter(Mandatory = $true)]
        [string]$DriverStoreRoot,
        [string]$PciInstanceId
    )

    $resolvedFolder = $null

    # First try to map published INF (oem*.inf) to Driver Store Path via pnputil output.
    $pnputilOutput = @(pnputil /enum-drivers /files 2>$null)
    if ($LASTEXITCODE -eq 0 -and $pnputilOutput.Count -gt 0)
    {
        $blockText = ""
        foreach ($line in $pnputilOutput)
        {
            if ([string]::IsNullOrWhiteSpace($line))
            {
                if ($blockText -match '(?im)^\s*Published\s+Name\s*:\s*([^\r\n]+)')
                {
                    $publishedName = $matches[1].Trim()
                    if ($publishedName -ieq $PublishedInfName)
                    {
                        if ($blockText -match '(?im)^\s*Driver\s+Store\s+Path\s*:\s*([^\r\n]+)')
                        {
                            $driverStorePath = $matches[1].Trim()
                            if (Test-Path $driverStorePath)
                            {
                                $resolvedFolder = Split-Path -Path $driverStorePath -Parent
                                break
                            }
                        }
                    }
                }

                $blockText = ""
            }
            else
            {
                $blockText += $line + "`n"
            }
        }

        if (-not $resolvedFolder -and $blockText)
        {
            if ($blockText -match '(?im)^\s*Published\s+Name\s*:\s*([^\r\n]+)')
            {
                $publishedName = $matches[1].Trim()
                if ($publishedName -ieq $PublishedInfName)
                {
                    if ($blockText -match '(?im)^\s*Driver\s+Store\s+Path\s*:\s*([^\r\n]+)')
                    {
                        $driverStorePath = $matches[1].Trim()
                        if (Test-Path $driverStorePath)
                        {
                            $resolvedFolder = Split-Path -Path $driverStorePath -Parent
                        }
                    }
                }
            }
        }
    }

    # Final fallback: find INF containing VEN/DEV tokens from PCI instance ID.
    if (-not $resolvedFolder -and $PciInstanceId)
    {
        $venToken = $null
        $devToken = $null
        if ($PciInstanceId -match '(VEN_[0-9A-F]{4})') { $venToken = $matches[1].ToUpperInvariant() }
        if ($PciInstanceId -match '(DEV_[0-9A-F]{4})') { $devToken = $matches[1].ToUpperInvariant() }

        if ($venToken -and $devToken)
        {
            $infFiles = Get-ChildItem -Path $DriverStoreRoot -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue
            $tokenMatches = @()
            foreach ($infFile in $infFiles)
            {
                $hit = Select-String -Path $infFile.FullName -Pattern "$venToken","$devToken" -SimpleMatch -Quiet -ErrorAction SilentlyContinue
                if ($hit)
                {
                    $header = @(Get-Content -Path $infFile.FullName -TotalCount 120 -ErrorAction SilentlyContinue)
                    $classLine = ($header | Where-Object { $_ -match '^\s*Class\s*=' } | Select-Object -First 1)
                    $className = ''
                    if ($classLine -match '^\s*Class\s*=\s*(.+)$')
                    {
                        $className = $matches[1].Trim()
                    }

                    $score = 0
                    if ($className -match '(?i)compute|neural') { $score += 20 }
                    if ($className -match '(?i)extension|softwarecomponent') { $score -= 25 }
                    if ($infFile.Name -match '(?i)npu|neural|aiboost|intelai|ipu') { $score += 10 }
                    if ($infFile.Name -match '(?i)extension|dma|sec') { $score -= 10 }

                    $tokenMatches += [PSCustomObject]@{
                        Score = $score
                        Folder = $infFile.DirectoryName
                        Inf = $infFile.Name
                        Class = $className
                    }
                }
            }

            if ($tokenMatches.Count -gt 0)
            {
                $bestMatch = $tokenMatches | Sort-Object -Property Score -Descending | Select-Object -First 1
                $resolvedFolder = $bestMatch.Folder
                Write-Host "INF token fallback selected package:" $bestMatch.Inf "| Class:" $bestMatch.Class
            }
        }
    }

    return $resolvedFolder
}

# Credential Building
$password = ConvertTo-SecureString "$password" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($user,$password)

# Registry entries required
New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV" -Name "RequireSecureDeviceAssignment" -Type DWORD -Value 0 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV" -Name "RequireSupportedDeviceAssignment" -Type DWORD -Value 0 -Force

# Stop the Virtual Machine
Write-Host "Shutting Down Virtual Machine: $vm" 
Stop-VM $vm
# Disable Checkpoints if they haven't been already
Write-Host "Disabling Checkpoints on Virtual Machine: $vm" 
Set-VM $vm -CheckpointType Disabled 

# Get partitionable devices we can work with
$partitionableGpus = @(Get-VMHostPartitionableGpu)

if ($partitionableGpus.Count -eq 0)
{
    Write-Host "No partitionable GPUs were found on the host, exiting script"
    exit
}

# Build a map of display-class PCI IDs to partitionable devices.
$displayPnpIds = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PNPDeviceID)
$displayPciTokens = @($displayPnpIds | ForEach-Object { $_.ToUpperInvariant().Replace("\\", "#") })

$displayPartitionableDevices = @(
    $partitionableGpus | Where-Object {
        $partitionableName = $_.Name.ToUpperInvariant()
        $isDisplay = $false

        foreach ($token in $displayPciTokens)
        {
            if ($partitionableName -like "*$token*")
            {
                $isDisplay = $true
                break
            }
        }

        $isDisplay
    }
)

$nonDisplayPartitionableDevices = @(
    $partitionableGpus | Where-Object {
        $partitionableName = $_.Name.ToUpperInvariant()
        $isDisplay = $false

        foreach ($token in $displayPciTokens)
        {
            if ($partitionableName -like "*$token*")
            {
                $isDisplay = $true
                break
            }
        }

        -not $isDisplay
    }
)

$gpuCandidates = $partitionableGpus
if ($displayPartitionableDevices.Count -gt 0)
{
    # Prefer display-class devices so Intel NPUs do not get picked as the primary GPU.
    $gpuCandidates = $displayPartitionableDevices
}

if ($preferredGpuIdToken)
{
    $gpuCandidates = @($partitionableGpus | Where-Object { $_.Name -like "*$preferredGpuIdToken*" })

    if ($gpuCandidates.Count -eq 0)
    {
        Write-Host "No partitionable GPU matched preferred token '$preferredGpuIdToken', using auto-selection"
        $gpuCandidates = if ($displayPartitionableDevices.Count -gt 0) { $displayPartitionableDevices } else { $partitionableGpus }
    }
}

if ($gpuCandidates.Count -gt 1)
{
    Write-Host "Multiple primary GPU candidates matched; selecting the first one:" $gpuCandidates[0].Name
}

$gpu = $gpuCandidates[0]
$gpuDetails = ($gpu | Out-String)
$isIntelGpu = $false

$npu = $null
if ($enableNpuProvisioning)
{
    $npuCandidates = @($nonDisplayPartitionableDevices | Where-Object { $_.Name -ne $gpu.Name })

    if ($preferredNpuIdToken)
    {
        $npuCandidates = @($partitionableGpus | Where-Object { $_.Name -like "*$preferredNpuIdToken*" -and $_.Name -ne $gpu.Name })
    }

    if ($npuCandidates.Count -gt 0)
    {
        if ($npuCandidates.Count -gt 1)
        {
            Write-Host "Multiple NPU/non-display candidates matched; selecting the first one:" $npuCandidates[0].Name
        }

        $npu = $npuCandidates[0]
        Write-Host "Selected additional non-display partitionable device:" $npu.Name
    }
    else
    {
        Write-Host "NPU provisioning requested, but no additional non-display partitionable device was found"
    }
}

# Remove the existing GPU-P Adapter if already assigned
Write-Host "Removing GPU-P Adapter"
Remove-VMGpuPartitionAdapter -VMName $vm

# Build adapter target list
$partitionTargets = @($gpu)

$addGpuPartitionCmd = Get-Command Add-VMGpuPartitionAdapter -ErrorAction SilentlyContinue
$setGpuPartitionCmd = Get-Command Set-VMGpuPartitionAdapter -ErrorAction SilentlyContinue
$supportsAddInstancePath = $false
$supportsSetAdapterId = $false

if ($addGpuPartitionCmd -and $setGpuPartitionCmd)
{
    $supportsAddInstancePath = $addGpuPartitionCmd.Parameters.ContainsKey('InstancePath')
    $supportsSetAdapterId = $setGpuPartitionCmd.Parameters.ContainsKey('AdapterId')
}

if ($npu)
{
    if ($supportsAddInstancePath -and $supportsSetAdapterId)
    {
        $partitionTargets += $npu
    }
    else
    {
        Write-Host "NPU provisioning requested, but this Hyper-V module does not support the required GPU-P targeting parameters; skipping NPU"
    }
}

# Add the Partition Adapter(s) to the Guest Virtual Machine
Write-Host "Adding GPU-P Adapter(s)"
if ($supportsAddInstancePath)
{
    foreach ($target in $partitionTargets)
    {
        Add-VMGpuPartitionAdapter -VMName $vm -InstancePath $target.Name
    }
}
else
{
    Add-VMGpuPartitionAdapter -VMName $vm
}

# Set the values of the partitioned adapter(s)
Write-Host "Setting GPU-P Adapter Parameters"
# Production 100%
if ($supportsAddInstancePath -and $supportsSetAdapterId)
{
    $vmPartitionAdapters = @(Get-VMGpuPartitionAdapter -VMName $vm)

    foreach ($target in $partitionTargets)
    {
        $matchingAdapter = $vmPartitionAdapters | Where-Object { $_.InstancePath -eq $target.Name } | Select-Object -First 1

        if (-not $matchingAdapter)
        {
            Write-Host "Could not find VM GPU partition adapter for target:" $target.Name
            continue
        }

        $adapterId = $null
        if ($matchingAdapter.PSObject.Properties.Name -contains 'AdapterId')
        {
            $adapterId = $matchingAdapter.AdapterId
        }
        elseif ($matchingAdapter.PSObject.Properties.Name -contains 'Id')
        {
            $adapterId = $matchingAdapter.Id
        }

        if (-not $adapterId)
        {
            Write-Host "Could not resolve AdapterId for target:" $target.Name
            continue
        }

        Set-VMGpuPartitionAdapter -VMName $vm -AdapterId $adapterId -MinPartitionVRAM ($target.MinPartitionVRAM) -MaxPartitionVRAM ($target.MaxPartitionVRAM) -OptimalPartitionVRAM ($target.OptimalPartitionVRAM) -MinPartitionEncode ($target.MinPartitionEncode) -MaxPartitionEncode ($target.MaxPartitionEncode) -OptimalPartitionEncode ($target.OptimalPartitionEncode) -MinPartitionDecode ($target.MinPartitionDecode) -MaxPartitionDecode $target.MaxPartitionDecode -OptimalPartitionDecode ($target.OptimalPartitionDecode) -MinPartitionCompute ($target.MinPartitionCompute) -MaxPartitionCompute ($target.MaxPartitionCompute) -OptimalPartitionCompute ($target.OptimalPartitionCompute)
    }
}
else
{
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM ($gpu.MinPartitionVRAM) -MaxPartitionVRAM ($gpu.MaxPartitionVRAM) -OptimalPartitionVRAM ($gpu.OptimalPartitionVRAM) -MinPartitionEncode ($gpu.MinPartitionEncode) -MaxPartitionEncode ($gpu.maxPartitionEncode) -OptimalPartitionEncode ($gpu.OptimalPartitionEncode) -MinPartitionDecode ($gpu.MinPartitionDecode) -MaxPartitionDecode $gpu.MaxPartitionDecode -OptimalPartitionDecode ($gpu.OptimalPartitionDecode) -MinPartitionCompute ($gpu.MinPartitionCompute) -MaxPartitionCompute ($gpu.MaxPartitionCompute) -OptimalPartitionCompute ($gpu.OptimalPartitionCompute)
}

# Testing, setting max to less than 100% 
# $factor = .8
# Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM ($gpu.MinPartitionVRAM) -MaxPartitionVRAM ($gpu.MaxPartitionVRAM) -OptimalPartitionVRAM ($gpu.OptimalPartitionVRAM) -MinPartitionEncode ($gpu.MinPartitionEncode) -MaxPartitionEncode ($gpu.maxPartitionEncode * $factor) -OptimalPartitionEncode ($gpu.OptimalPartitionEncode * $factor) -MinPartitionDecode ($gpu.MinPartitionDecode) -MaxPartitionDecode ($gpu.MaxPartitionDecode * $factor) -OptimalPartitionDecode ($gpu.OptimalPartitionDecode * $factor) -MinPartitionCompute ($gpu.MinPartitionCompute) -MaxPartitionCompute ($gpu.MaxPartitionCompute * $factor) -OptimalPartitionCompute ($gpu.OptimalPartitionCompute  * $factor)

# Required Items
Write-Host "Setting VM Options"
Set-VM -GuestControlledCacheTypes $true -VMName $vm
Set-VM -LowMemoryMappedIoSpace 3Gb -VMName $vm
Set-VM -HighMemoryMappedIoSpace 32GB -VMName $vm

# Enable the Guest Service Integration to use PowerShell Direct / Copy Files 
Write-Host "Enabling Guest Service Interface"
Enable-VMIntegrationService $vm -Name 'Guest Service Interface'

# Start the Virtual Machine
Write-Host "Starting up Virtual Machine: $vm"
Start-VM $vm 

Write-Host "Waiting on Virtual Machine Heartbeat on $vm"
while ((Get-VM $vm).Heartbeat -notlike "*ok*")
{
Write-Host "Still Waiting" 
Start-Sleep 10
}

Write-Host "Building PowerShell Session"
# Build Powershell Session to Copy the Driver Files 
$session = New-PSSession -VMName $vm -Credential $cred  

# Reference File Paths 
$pathhost = 'C:\Windows\System32\DriverStore\FileRepository\'
$pathguest = 'C:\Windows\System32\HostDriverStore\FileRepository\'
$pathguestroot = $pathguest


if ($gpuDetails -like "*VEN_1002*")
{
    Write-Host "GPU is AMD, continuing script"
    # Determine the driver path of the newest AMD driver on the host system
    $pathdriver = ((Get-ChildItem -Path $pathhost -Recurse amdxx64.dll | Sort-Object CreationTime -Descending | Select-Object -First 1).DirectoryName + "\")

    # Determine the driver folder name 
    $driverfolder = ($pathdriver -split "\\")[5,6] -join "\"
    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine" 
    Copy-DriverPackageToGuest -Session $session -SourceFolder $pathdriver -GuestDriverStoreRoot $pathguestroot -UseArchiveTransfer $useArchiveTransfer

    # Not needed on AMD 
    # Copies the amd*.dll files to system32 on the guest virtual machine
    # Get-ChildItem -Path C:\Windows\System32\amd*dll |  ForEach-Object { Copy-Item -ToSession $session -Path $_ -Destination C:\Windows\System32\ -Force }
    Write-Host "End File Copy to Guest Virtual Machine" 

}
elseif ($gpuDetails -like "*VEN_10DE*")
{
    Write-Host "GPU is Nvidia, continuing script"
    # Determine the driver path of the newest Nvidia driver on the host system
    $pathdriver = ((Get-ChildItem -Path $pathhost -Recurse nvapi64.dll  | Sort-Object CreationTime -Descending | Select-Object -First 1).DirectoryName + "\")

    # Determine the driver folder name 
    $driverfolder = ($pathdriver -split "\\")[5]
    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine" 
    Copy-DriverPackageToGuest -Session $session -SourceFolder $pathdriver -GuestDriverStoreRoot $pathguestroot -UseArchiveTransfer $useArchiveTransfer
    # Copies the nv*.dll files to system32 on the guest virtual machine except NvAgent.dll and nvspinfo.exe
    Get-ChildItem -Path C:\Windows\System32\nv*dll | Where-Object { $_.name -notlike 'NvAgent.dll' } | ForEach-Object { Copy-Item -ToSession $session -Path $_ -Destination C:\Windows\System32\ -Force }
    Write-Host "End File Copy to Guest Virtual Machine" 

}
elseif ($gpuDetails -like "*VEN_8086*")
{
    Write-Host "GPU is Intel, continuing script"
    $isIntelGpu = $true

    # Determine the driver path of the newest Intel driver on the host system.
    $intelDriverCandidates = @(
        "igdumdim64.dll",
        "igdumdim32.dll",
        "igd10iumd64.dll",
        "igd12umd64.dll"
    )

    $pathdriver = $null
    foreach ($candidate in $intelDriverCandidates)
    {
        $candidatePath = Get-ChildItem -Path $pathhost -Recurse -Filter $candidate -ErrorAction SilentlyContinue |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1

        if ($candidatePath)
        {
            $pathdriver = $candidatePath.DirectoryName + "\"
            break
        }
    }

    if (-not $pathdriver)
    {
        Write-Host "No supported Intel driver files were found in $pathhost, exiting script"
        Remove-PSSession $session
        exit
    }

    # Determine the driver folder name
    $driverfolder = ($pathdriver -split "\\")[5]
    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine"
    Copy-DriverPackageToGuest -Session $session -SourceFolder $pathdriver -GuestDriverStoreRoot $pathguestroot -UseArchiveTransfer $useArchiveTransfer

    # Copy Intel user-mode DLLs from the selected driver package only.
    # Avoid copying every host ig*.dll, which can introduce mismatched files in the guest.
    Get-ChildItem -Path $pathdriver -Filter ig*.dll -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item -ToSession $session -Path $_.FullName -Destination C:\Windows\System32\ -Force }

    if ($npu)
    {
        Write-Host "Locating Intel NPU driver package on host"
        $npuPciInstanceId = Get-PciInstanceIdFromPartitionableName -PartitionableName $npu.Name
        $normalizedNpuPciInstanceId = ($npuPciInstanceId -replace '\\+', '\').ToUpperInvariant()
        $npuLookupKey = ($normalizedNpuPciInstanceId -replace '\\', '')

        $npuSignedDriver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object {
                $deviceIdRaw = "$($_.DeviceID)"
                $pnpDeviceIdRaw = "$($_.PNPDeviceID)"
                $deviceIdNorm = (($deviceIdRaw -replace '\\+', '\').ToUpperInvariant() -replace '\\', '')
                $pnpDeviceIdNorm = (($pnpDeviceIdRaw -replace '\\+', '\').ToUpperInvariant() -replace '\\', '')

                ($deviceIdNorm -eq $npuLookupKey) -or ($pnpDeviceIdNorm -eq $npuLookupKey)
            } |
            Select-Object -First 1

        if ($npuSignedDriver -and $npuSignedDriver.InfName)
        {
            Write-Host "Resolved NPU host metadata:" $npuSignedDriver.DeviceName "| Class:" $npuSignedDriver.DeviceClass "| INF:" $npuSignedDriver.InfName

            $npuClassName = "$($npuSignedDriver.DeviceClass)"
            if ($npuClassName -match 'display')
            {
                Write-Host "Resolved device class appears to be Display, not Neural processor. Skipping NPU package copy for target:" $npuPciInstanceId
                Write-Host "Tip: set \$preferredNpuIdToken to the DEV_ value for the Intel AI Boost/NPU device"
            }
            else
            {
                $npuInfName = $npuSignedDriver.InfName
                $npuDriverFolderPath = (Get-ChildItem -Path $pathhost -Recurse -Filter $npuInfName -ErrorAction SilentlyContinue |
                    Sort-Object CreationTime -Descending |
                    Select-Object -First 1).DirectoryName

                if (-not $npuDriverFolderPath -and $npuInfName -like 'oem*.inf')
                {
                    Write-Host "INF appears to be published name ($npuInfName). Resolving DriverStore folder via associated files"
                    $associatedDriverFiles = @(Get-CimAssociatedInstance -InputObject $npuSignedDriver -Association Win32_PnPSignedDriverCIMDataFile -ErrorAction SilentlyContinue)
                    $driverStoreFile = $associatedDriverFiles |
                        Where-Object { $_.Name -like (Join-Path $pathhost '*') } |
                        Select-Object -First 1

                    if ($driverStoreFile)
                    {
                        $npuDriverFolderPath = Split-Path -Path $driverStoreFile.Name -Parent
                    }

                    if (-not $npuDriverFolderPath)
                    {
                        Write-Host "Associated file lookup failed. Trying pnputil and INF token fallback"
                        $npuDriverFolderPath = Resolve-DriverStoreFolderFromPublishedInf -PublishedInfName $npuInfName -DriverStoreRoot $pathhost -PciInstanceId $normalizedNpuPciInstanceId
                    }
                }

                if ($npuDriverFolderPath)
                {
                    $npuPathDriver = $npuDriverFolderPath + "\"

                    Write-Host "Copying Intel NPU driver package to guest"
                    Copy-DriverPackageToGuest -Session $session -SourceFolder $npuPathDriver -GuestDriverStoreRoot $pathguestroot -UseArchiveTransfer $useArchiveTransfer

                    Write-Host "Triggering in-guest driver scan to bind NPU device"
                    $npuFolderName = Split-Path -Path ($npuPathDriver.TrimEnd('\')) -Leaf
                    Invoke-Command -Session $session -ScriptBlock {
                        param($driverRoot, $folderName)
                        if (-not $driverRoot)
                        {
                            Write-Host "Guest driver root path is empty; skipping NPU INF install"
                            return
                        }

                        $packagePath = Join-Path $driverRoot $folderName
                        if (-not (Test-Path -Path $packagePath))
                        {
                            Write-Host "NPU package path not found in guest:" $packagePath
                            return
                        }

                        $infFiles = @(Get-ChildItem -Path $packagePath -Filter *.inf -File -ErrorAction SilentlyContinue)
                        if ($infFiles.Count -eq 0)
                        {
                            Write-Host "No INF files found in guest NPU package path:" $packagePath
                        }

                        foreach ($inf in $infFiles)
                        {
                            Write-Host "pnputil /add-driver $($inf.FullName) /install"
                            $pnpResult = pnputil /add-driver $inf.FullName /install 2>&1
                            Write-Host ($pnpResult -join "`n")
                        }
                        Write-Host "pnputil /scan-devices"
                        $scanResult = pnputil /scan-devices 2>&1
                        Write-Host ($scanResult -join "`n")

                        Write-Host "NPU runtime compatibility check"
                        $npuDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                            Where-Object {
                                $_.Class -eq 'ComputeAccelerator' -or
                                $_.InstanceId -like '*VEN_1414*DEV_008A*' -or
                                $_.InstanceId -like '*VEN_8086*DEV_AD1D*' -or
                                $_.FriendlyName -like '*AI Boost*'
                            })

                        if ($npuDevices.Count -eq 0)
                        {
                            Write-Host "NPU verdict: Not enumerated in guest"
                        }
                        else
                        {
                            foreach ($device in $npuDevices)
                            {
                                Write-Host ("NPU device: Status={0} Name={1} InstanceId={2}" -f $device.Status, $device.FriendlyName, $device.InstanceId)
                            }

                            $hasVirtualError = $npuDevices | Where-Object {
                                $_.InstanceId -like '*VEN_1414*DEV_008A*' -and $_.Status -eq 'Error'
                            }
                            $hasNativeStarted = $npuDevices | Where-Object {
                                $_.InstanceId -like '*VEN_8086*DEV_AD1D*' -and $_.Status -eq 'OK'
                            }

                            if ($hasNativeStarted)
                            {
                                Write-Host "NPU verdict: Native Intel NPU path is active in guest"
                            }
                            elseif ($hasVirtualError)
                            {
                                Write-Host "NPU verdict: Virtual compute fallback detected with error state; likely unsupported on current stack"
                            }
                            else
                            {
                                Write-Host "NPU verdict: Enumerated, but not in a confirmed started native state"
                            }
                        }
                    } -ArgumentList $pathguestroot, $npuFolderName
                }
                else
                {
                    Write-Host "Could not locate Intel NPU driver folder in DriverStore for INF:" $npuInfName
                }
            }
        }
        else
        {
            Write-Host "Could not resolve Intel NPU signed driver metadata from host for:" $npuPciInstanceId
        }
    }

    Write-Host "End File Copy to Guest Virtual Machine"

}
else
{
    Write-Host "GPU is not AMD, Nvidia, or Intel, exiting script"
    exit
}

if ($isIntelGpu -and $applyIntelRdpWorkaround)
{
    Write-Host "Applying Intel RDP stability workaround in guest"
    Invoke-Command -Session $session -ScriptBlock {
        $tsPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        if (-not (Test-Path $tsPolicyPath))
        {
            New-Item -Path $tsPolicyPath -Force | Out-Null
        }

        # Disable AVC444 priority and hardware AVC encoding to reduce protocol disconnects.
        Set-ItemProperty -Path $tsPolicyPath -Name 'AVC444ModePreferred' -Type DWord -Value 0 -Force
        Set-ItemProperty -Path $tsPolicyPath -Name 'AVCHardwareEncodePreferred' -Type DWord -Value 0 -Force
    }
}

# Remove PSSession
Write-Host "Removing PowerShell Session"
Remove-PSSession $session

# Restart the Guest Virtual Machine to Enable the GPU 
Write-Host "Restarting Virtual Machine $vm to enable GPU"
Write-Host "Shutting Down Virtual Machine: $vm" 
Stop-VM $vm 
Write-Host "Starting up Virtual Machine: $vm"
Start-VM $vm
