# Prerequiste: Connection to Exchange Online v1 or v2 powershell
# This article handles pages better https://cynicalsys.com/2019/09/13/working-with-large-exchange-messages-traces-in-powershell/

# How many days back do we want to look?  
$days = '7'
# How many top senders do you want detail on?
$topsenders = '10'
# Output location
$path = 'c:\temp' 

# Set Start and End date based on parameter above
$startdate = ((Get-Date).AddDays(-$days).ToUniversalTime())
$enddate = ((Get-Date).ToUniversalTime())

# get domain name for csv output
$domain = ((Get-AcceptedDomain | ? {$_.default -eq $true}).name -replace '\.','_')

# for iteration of pages
$count = 1..100
# Empty array declaration
$final = @()

# Iterate through each page of message trace and add to the final array
foreach ($count in $count){

# Get each page of results
$result = Get-MessageTrace -StartDate $startdate -EndDate $enddate -PageSize 5000 -Page $count 

# Add page to final array
$final += $result
}

# Output of total emails
Write-Host ($final | measure).Count "Emails between" $startdate "and" $enddate "UTC" -ForegroundColor Yellow

# Output of top senders
Write-Host "Output all senders to $path\$($domain)_senders.csv" -ForegroundColor Yellow
$final | Group-Object senderaddress | Sort-Object count -Descending | Export-Csv -NoTypeInformation "$path\$($domain)_senders.csv"

# Output of top x sender emails
Write-Host "Output Top $topsenders senders to $path\$($domain)_top10_senders_detail.csv" -ForegroundColor Yellow
$final | Group-Object senderaddress | Sort-Object count -Descending | Select-Object -First $topsenders | Select-Object -ExpandProperty group | Export-Csv -NoTypeInformation "$path\$($domain)_top10_senders_detail.csv"
