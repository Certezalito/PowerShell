# Getting winget working on Windows Server 2022

# Reference: 
# https://github.com/microsoft/winget-cli/issues/700#issuecomment-874084714
# https://gist.github.com/maxkoshevoi/60d7b7910ad6ddcc6e1c9b656a8d0301

# Working folder for downloading and installing from, change this if you wish
$folder = "$env:USERPROFILE" + "\Downloads"

# Pre-requistes for Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle:
# Microsoft.UI.Xaml.2.7 AND Microsoft.VCLibs.140.00.UWPDesktop
Invoke-WebRequest https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.7.3/Microsoft.UI.Xaml.2.7.x64.appx -OutFile $folder\Microsoft.UI.Xaml.2.7.x64.appx
Add-AppxPackage $folder\Microsoft.UI.Xaml.2.7.x64.appx
Invoke-WebRequest https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx -OutFile $folder\Microsoft.VCLibs.x64.14.00.Desktop.appx 
Add-AppxPackage $folder\Microsoft.VCLibs.x64.14.00.Desktop.appx 

# Get winget
Invoke-WebRequest https://aka.ms/getwingetpreview -OutFile $folder\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
# Get winget license
$latestlicense=(Invoke-WebRequest https://api.github.com/repos/microsoft/winget-cli/releases/latest | ConvertFrom-Json ).assets | where {$_.name -like "*xml"} 
Invoke-WebRequest $latestlicense.browser_download_url -OutFile ($folder + "\" + ($latestlicense.name))

# Install winget / "app installer"
Add-AppxProvisionedPackage -Online -PackagePath $folder\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle -LicensePath ($folder + "\" + ($latestlicense.name))



# Testing

# Install WSL
# wsl --install

# A method to install Alma Linux 9 in wsl 
# winget install 9P5RWLM70SN9 -s msstore  --accept-source-agreements --accept-package-agreements 
# winget install --id 9P5RWLM70SN9 --exact

# Install Windows Terminal
# DNU winget install 9N0DX20HK701 -s msstore  --accept-source-agreements --accept-package-agreements 
# winget install --id Microsoft.WindowsTerminal --exact