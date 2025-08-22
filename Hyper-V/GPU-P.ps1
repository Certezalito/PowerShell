# Script to setup a Virtual Machine Guest with an AMD or Nvidia GPU-P Adapter
# Script will copy driver files to Guest Virtual Machine, rerun script when driver updates
# Script will disable checkpoints
# Assumptions: There is one GPU to Partition, either AMD or Nvidia, script is running as admin, you connect to machine as basic session, dynamic memory is disabled
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

# Credential Building
$password = ConvertTo-SecureString "$password" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($user,$password)

# Registry entries required
New-Item HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV" -Name "RequireSecureDeviceAssignment" -Type DWORD -Value 0 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV" -Name "RequireSupportedDeviceAssignment" -Type DWORD -Value 0 -Force

# Stop the Virtual Machine
Write-Host "Shutting Down Virtual Machine: $vm" 
Stop-VM $vm
# Disable Checkpoints if they haven't been already
Write-Host "Disabling Checkpoints on Virtual Machine: $vm" 
Set-VM $vm -CheckpointType Disabled 

# Get the GPU we are working with 
$gpu = Get-VMHostPartitionableGpu

# Remove the existing GPU-P Adapter if already assigned
Write-Host "Removing GPU-P Adapter"
Remove-VMGpuPartitionAdapter -VMName $vm

# Add the Partition Adapter to the Guest Virtual Machine
Write-Host "Adding GPU-P Adapter"
Add-VMGpuPartitionAdapter -VMName $vm

# Set the values of the GPU partitioned adapter
Write-Host "Setting GPU-P Adapter Parameters"
# Production 100%
Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM ($gpu.MinPartitionVRAM) -MaxPartitionVRAM ($gpu.MaxPartitionVRAM) -OptimalPartitionVRAM ($gpu.OptimalPartitionVRAM) -MinPartitionEncode ($gpu.MinPartitionEncode) -MaxPartitionEncode ($gpu.maxPartitionEncode) -OptimalPartitionEncode ($gpu.OptimalPartitionEncode) -MinPartitionDecode ($gpu.MinPartitionDecode) -MaxPartitionDecode $gpu.MaxPartitionDecode -OptimalPartitionDecode ($gpu.OptimalPartitionDecode) -MinPartitionCompute ($gpu.MinPartitionCompute) -MaxPartitionCompute ($gpu.MaxPartitionCompute) -OptimalPartitionCompute ($gpu.OptimalPartitionCompute)

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


if ($gpu -like "*VEN_1002*")
{
    Write-Host "GPU is AMD, continuing script"
    # Determine the driver path of the newest AMD driver on the host system
    $pathdriver = ((Get-ChildItem -Path $pathhost -Recurse amdxx64.dll | Sort-Object CreationTime -Descending | Select-Object -First 1).DirectoryName + "\")

    # Determine the driver folder name 
    $driverfolder = ($pathdriver -split "\\")[5,6] -join "\"
    # Update guest folder path with driver folder name 
    $pathguest = $pathguest + $driverfolder + "\"

    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine" 
    Copy-Item -ToSession $session -Path $pathdriver -Destination $pathguest -Recurse -Force

    # Not needed on AMD 
    # Copies the amd*.dll files to system32 on the guest virtual machine
    # Get-ChildItem -Path C:\Windows\System32\amd*dll |  ForEach-Object { Copy-Item -ToSession $session -Path $_ -Destination C:\Windows\System32\ -Force }
    Write-Host "End File Copy to Guest Virtual Machine" 

}
elseif ($gpu -like "*VEN_10DE*")
{
    Write-Host "GPU is Nvidia, continuing script"
    # Determine the driver path of the newest Nvidia driver on the host system
    $pathdriver = ((Get-ChildItem -Path $pathhost -Recurse nvapi64.dll  | Sort-Object CreationTime -Descending | Select-Object -First 1).DirectoryName + "\")

    # Determine the driver folder name 
    $driverfolder = ($pathdriver -split "\\")[5]
    # Update guest folder path with driver folder name 
    $pathguest = $pathguest + $driverfolder + "\"

    # Copies the driver folder to the guest folder path
    Write-Host "Beginning File Copy to Guest Virtual Machine" 
    Copy-Item -ToSession $session -Path $pathdriver -Destination $pathguest -Recurse -Force
    # Copies the nv*.dll files to system32 on the guest virtual machine except NvAgent.dll and nvspinfo.exe (?)
    Get-ChildItem -Path C:\Windows\System32\nv*dll | ? {$_.name -notlike 'NvAgent.dll'} | ForEach-Object { Copy-Item -ToSession $session -Path $_ -Destination C:\Windows\System32\ -Force }
    Write-Host "End File Copy to Guest Virtual Machine" 

    }
else
{
    Write-Host "GPU is not AMD or Nvidia, exiting script"
    exit
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
