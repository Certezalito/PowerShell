# Script to trigger a Microsoft Safety Scanner Download and log the results to CSV

# Remediation and Log Gathering
$hostname = hostname 

# Download MSERT 64-bit 
# need 32/64 bit logic 
Write-host Downloading File
Invoke-WebRequest -Uri https://go.microsoft.com/fwlink/?LinkId=212732 -OutFile c:\temp\MSERT.exe

# Execute MSERT silent full scan
Write-Host Running MSERT
C:\temp\MSERT.exe /q /f 

# Wait for scan to finish
Write-Host Waiting on MSERT to finish
Wait-Process msert  

# Copy log to c:\temp
Write-Host Copy log to c:\temp
Copy-Item -path $env:SYSTEMROOT\debug\msert.log C:\temp\$hostname-remediation-msert.log 

# Sometime Defender will find the shell before MSERT will, grab those logs as well
Get-WinEvent 'Microsoft-Windows-Windows Defender/Operational' | Export-csv c:\temp\$hostname-DefenderEvents-Remediation.csv 