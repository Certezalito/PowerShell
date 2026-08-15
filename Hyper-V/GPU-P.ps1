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
# https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues#step-8-check-the-vm-configuration

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
# Optional: If RDP is UDP, this will be needed, however it introduces latency.  Guest RDP fallback for protocol disconnects. Can improve stability but may increase latency; keep disabled unless needed.
$applyIntelRdpWorkaround = $false
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

        # Use native tar.exe to bypass PowerShell 5.1 260-character path limits
        & tar.exe -a -c -f "$hostTempZip" -C "$resolvedSourceFolder" *

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

        Set-VMGpuPartitionAdapter -VMName $vm -AdapterId $adapterId -MinPartitionVRAM ([uint64]$target.MinPartitionVRAM) -MaxPartitionVRAM ([uint64]$target.MaxPartitionVRAM) -OptimalPartitionVRAM ([uint64]$target.OptimalPartitionVRAM) -MinPartitionEncode ([uint64]$target.MinPartitionEncode) -MaxPartitionEncode ([uint64]$target.MaxPartitionEncode) -OptimalPartitionEncode ([uint64]$target.OptimalPartitionEncode) -MinPartitionDecode ([uint64]$target.MinPartitionDecode) -MaxPartitionDecode ([uint64]$target.MaxPartitionDecode) -OptimalPartitionDecode ([uint64]$target.OptimalPartitionDecode) -MinPartitionCompute ([uint64]$target.MinPartitionCompute) -MaxPartitionCompute ([uint64]$target.MaxPartitionCompute) -OptimalPartitionCompute ([uint64]$target.OptimalPartitionCompute)
    }
}
else
{
    Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM ([uint64]$gpu.MinPartitionVRAM) -MaxPartitionVRAM ([uint64]$gpu.MaxPartitionVRAM) -OptimalPartitionVRAM ([uint64]$gpu.OptimalPartitionVRAM) -MinPartitionEncode ([uint64]$gpu.MinPartitionEncode) -MaxPartitionEncode ([uint64]$gpu.maxPartitionEncode) -OptimalPartitionEncode ([uint64]$gpu.OptimalPartitionEncode) -MinPartitionDecode ([uint64]$gpu.MinPartitionDecode) -MaxPartitionDecode ([uint64]$gpu.MaxPartitionDecode) -OptimalPartitionDecode ([uint64]$gpu.OptimalPartitionDecode) -MinPartitionCompute ([uint64]$gpu.MinPartitionCompute) -MaxPartitionCompute ([uint64]$gpu.MaxPartitionCompute) -OptimalPartitionCompute ([uint64]$gpu.OptimalPartitionCompute)
}

# Testing, setting max to less than 100% 
# $factor = .8
# Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM ($gpu.MinPartitionVRAM) -MaxPartitionVRAM ($gpu.MaxPartitionVRAM) -OptimalPartitionVRAM ($gpu.OptimalPartitionVRAM) -MinPartitionEncode ($gpu.MinPartitionEncode) -MaxPartitionEncode ($gpu.maxPartitionEncode * $factor) -OptimalPartitionEncode ($gpu.OptimalPartitionEncode * $factor) -MinPartitionDecode ($gpu.MinPartitionDecode) -MaxPartitionDecode ($gpu.MaxPartitionDecode * $factor) -OptimalPartitionDecode ($gpu.OptimalPartitionDecode * $factor) -MinPartitionCompute ($gpu.MinPartitionCompute) -MaxPartitionCompute ($gpu.MaxPartitionCompute * $factor) -OptimalPartitionCompute ($gpu.OptimalPartitionCompute  * $factor)

# Required Items
Write-Host "Setting VM Options (MMIO, Dynamic Memory, Stop Action)"
Set-VM -GuestControlledCacheTypes $true -VMName $vm
Set-VM -LowMemoryMappedIoSpace 3Gb -VMName $vm
# Increased to 128GB to support high-VRAM GPUs (24GB+) without exhausting virtual address space
Set-VM -HighMemoryMappedIoSpace 128Gb -VMName $vm

# Enforce Dynamic Memory to False (GPU-P fails if memory fluctuates)
Set-VMMemory -VMName $vm -DynamicMemoryEnabled $false

# Enforce Stop Action (GPU-P VMs cannot handle "Save State" when the host reboots)
Set-VM -VMName $vm -AutomaticStopAction ShutDown

# Enable the Guest Service Integration to use PowerShell Direct / Copy Files 
Write-Host "Enabling Guest Service Interface"
Enable-VMIntegrationService $vm -Name 'Guest Service Interface'

# Start the Virtual Machine
Write-Host "Starting up Virtual Machine: $vm"
Start-VM $vm 

Write-Host "Waiting on Virtual Machine Heartbeat on $vm"
while ((Get-VM $vm).Heartbeat -notlike "*ok*")
{
    Write-Host "Still Waiting for Heartbeat..." 
    Start-Sleep 10
}

Write-Host "Building PowerShell Session. Waiting for PowerShell Direct listener..."
$session = $null
while (-not $session) {
    try {
        $session = New-PSSession -VMName $vm -Credential $cred -ErrorAction Stop
    } catch {
        Write-Host "Waiting for WinRM inside guest to accept connections..."
        Start-Sleep -Seconds 5
    }
}

# Apply Enhanced Session Mode RDP hardware acceleration fix
Invoke-Command -Session $session -ScriptBlock {
    $tsPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    if (-not (Test-Path $tsPolicyPath)) { New-Item -Path $tsPolicyPath -Force | Out-Null }
    # Forces RDP to use the hardware graphics adapter instead of MS Remote Display Adapter
    Set-ItemProperty -Path $tsPolicyPath -Name 'bEnumerateHWRequirementFailed' -Type DWord -Value 0 -Force
    Set-ItemProperty -Path $tsPolicyPath -Name 'fEnableWddmDriver' -Type DWord -Value 1 -Force
}

# Reference File Paths 
$pathhost = 'C:\Windows\System32\DriverStore\FileRepository\'
$pathguest = 'C:\Windows\System32\HostDriverStore\FileRepository\'
$pathguestroot = $pathguest


if ($gpuDetails -like "*VEN_1002*")
{
    Write-Host "GPU is AMD, continuing script"
    # Discover the active AMD display driver dynamically
    $amdSignedDriver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceClass -match 'Display' -and ($_.DeviceID -match 'VEN_1002' -or $_.PNPDeviceID -match 'VEN_1002') } |
        Select-Object -First 1

    $pathdriver = $null
    if ($amdSignedDriver -and $amdSignedDriver.InfName)
    {
        Write-Host "Resolved active AMD GPU host metadata: $($amdSignedDriver.DeviceName) | INF: $($amdSignedDriver.InfName)"
        $pathdriver = Resolve-DriverStoreFolderFromPublishedInf -PublishedInfName $amdSignedDriver.InfName -DriverStoreRoot $pathhost
    }

    if ($pathdriver) {
        if (-not $pathdriver.EndsWith("\")) { $pathdriver += "\" }
    } else {
        Write-Host "No active AMD driver folder could be resolved, exiting script"
        Remove-PSSession $session
        exit
    }

    # Determine the driver folder name 
    $driverfolder = ($pathdriver -split "\\")[-2]
    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine" 
    Copy-DriverPackageToGuest -Session $session -SourceFolder $pathdriver -GuestDriverStoreRoot $pathguestroot -UseArchiveTransfer $useArchiveTransfer

    Write-Host "End File Copy to Guest Virtual Machine" 

}
elseif ($gpuDetails -like "*VEN_10DE*")
{
    Write-Host "GPU is Nvidia, continuing script"
    # Discover the active Nvidia display driver dynamically
    $nvSignedDriver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceClass -match 'Display' -and ($_.DeviceID -match 'VEN_10DE' -or $_.PNPDeviceID -match 'VEN_10DE') } |
        Select-Object -First 1

    $pathdriver = $null
    if ($nvSignedDriver -and $nvSignedDriver.InfName)
    {
        Write-Host "Resolved active Nvidia GPU host metadata: $($nvSignedDriver.DeviceName) | INF: $($nvSignedDriver.InfName)"
        $pathdriver = Resolve-DriverStoreFolderFromPublishedInf -PublishedInfName $nvSignedDriver.InfName -DriverStoreRoot $pathhost
    }

    if ($pathdriver) {
        if (-not $pathdriver.EndsWith("\")) { $pathdriver += "\" }
    } else {
        Write-Host "No active Nvidia driver folder could be resolved, exiting script"
        Remove-PSSession $session
        exit
    }

    # Determine the driver folder name 
    $driverfolder = ($pathdriver -split "\\")[-2]
    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine" 
    Copy-DriverPackageToGuest -Session $session -SourceFolder $pathdriver -GuestDriverStoreRoot $pathguestroot -UseArchiveTransfer $useArchiveTransfer
    
    # Copies the nv*.dll files to system32 and syswow64 on the guest virtual machine
    Get-ChildItem -Path $pathdriver -Filter nv*dll | Where-Object { $_.name -notlike 'NvAgent.dll' } | ForEach-Object { 
        Copy-Item -ToSession $session -Path $_.FullName -Destination C:\Windows\System32\ -Force 
    }
    Write-Host "End File Copy to Guest Virtual Machine" 

}
elseif ($gpuDetails -like "*VEN_8086*")
{
    Write-Host "GPU is Intel, continuing script"
    $isIntelGpu = $true

    # Discover the active Intel display driver dynamically instead of guessing by CreationTime
    $intelSignedDriver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceClass -match 'Display' -and ($_.DeviceID -match 'VEN_8086' -or $_.PNPDeviceID -match 'VEN_8086') } |
        Select-Object -First 1

    $pathdriver = $null
    if ($intelSignedDriver -and $intelSignedDriver.InfName)
    {
        Write-Host "Resolved active Intel GPU host metadata: $($intelSignedDriver.DeviceName) | INF: $($intelSignedDriver.InfName)"
        $pathdriver = Resolve-DriverStoreFolderFromPublishedInf -PublishedInfName $intelSignedDriver.InfName -DriverStoreRoot $pathhost
    }

    if ($pathdriver) {
        # Ensure path ends with a slash for the copy functions
        if (-not $pathdriver.EndsWith("\")) { $pathdriver += "\" }
    } else {
        Write-Host "No active Intel driver folder could be resolved via PnP metadata, exiting script"
        Remove-PSSession $session
        exit
    }

    # Determine the driver folder name
    $driverfolder = ($pathdriver -split "\\")[-2] # More reliable than hardcoded index [5]

    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine"
    Copy-DriverPackageToGuest -Session $session -SourceFolder $pathdriver -GuestDriverStoreRoot $pathguestroot -UseArchiveTransfer $useArchiveTransfer

    # Copy user-mode DLLs (Expanding filter to include intel*.dll for newer Arc/Compute support)
    Get-ChildItem -Path $pathdriver -Include ig*.dll, intel*.dll -File -ErrorAction SilentlyContinue |
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

Write-Host "Executing Guest-Side Registry Injection for Compute & 32-bit capabilities"
Invoke-Command -Session $session -ScriptBlock {
    # 1. Provide a SysWOW64 driver link if a 32-bit game/app needs it
    $sysWowPath = "C:\Windows\SysWOW64"
    if (Test-Path $sysWowPath) {
        # Fallback mechanism: Many 32-bit apps fail to find the HostDriverStore, copy 32-bit DLLs if available
        # Note: True WDDM copies usually rely on mapping, but explicit copies help legacy apps.
        Get-ChildItem -Path "C:\Windows\System32\HostDriverStore\FileRepository\*" -Include *32.dll -Recurse -File -ErrorAction SilentlyContinue | 
            ForEach-Object { Copy-Item $_.FullName -Destination $sysWowPath -Force -ErrorAction SilentlyContinue }
    }

    # 2. Inject Vulkan & OpenCL ICD pointers so hardware compute works in the guest
    $driverStorePath = "C:\Windows\System32\HostDriverStore\FileRepository"
    $vulkanKey = "HKLM:\SOFTWARE\Khronos\Vulkan\Drivers"
    $openClKey = "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors"
    
    if (-not (Test-Path $vulkanKey)) { New-Item -Path $vulkanKey -Force | Out-Null }
    if (-not (Test-Path $openClKey)) { New-Item -Path $openClKey -Force | Out-Null }

    Get-ChildItem -Path $driverStorePath -Filter "*vulkan*.json" -Recurse -ErrorAction SilentlyContinue | 
        ForEach-Object { Set-ItemProperty -Path $vulkanKey -Name $_.FullName -Value 0 -Type DWord -Force }
        
    Get-ChildItem -Path $driverStorePath -Filter "*opencl*.json" -Recurse -ErrorAction SilentlyContinue | 
        ForEach-Object { Set-ItemProperty -Path $openClKey -Name $_.FullName -Value 0 -Type DWord -Force }
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
