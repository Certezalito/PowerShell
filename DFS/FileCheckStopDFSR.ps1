# Script to check the size difference over a timeperiod and shut down DFS Replication if the threshold is passed

#[Location] of DFSR Folder to monitor
$location = 'E:\blah\'

#[Set] interval to check DFSR Folder and convert to minutes 
$timetowaitinseconds = 900  # 900 seconds is 15 minutes 
$timetowaitinminutes = (New-TimeSpan -Seconds $timetowaitinseconds).Minutes

#[Size] in GB to monitor the difference
$sizemonitoredamount = '20' 

#[Get] initial size of DFSR Folder 
$sizeinitial = (Get-ChildItem $location | Measure-Object -Sum Length).sum

#[Wait] for interval to complete 
Start-Sleep -Seconds $timetowaitinseconds

#[Check] for DFSR size after interval 
$size = (Get-ChildItem $location | Measure-Object -Sum Length).sum

#[Compare] size difference between intial and interval 
$sizedifference = $sizeinitial - $size 

#[Check] if size decremented is greater than or equal to monitored amount
if ($sizedifference/1gb -ge $sizemonitoredamount)
{
Write-Host ($sizedifference/1gb)GB change is greater than ($sizemonitoredamount)GB threshold in $timetowaitinminutes minutes -ForegroundColor Red
Write-Host Shutting down DFSR -ForegroundColor Red

#[Shutdown] DFSR
Set-Service DFSR -StartupType Disabled -Verbose
Stop-Service DFSR -Verbose
Write-Host DFSR has been shutdown
}

else
{
Write-Host ($sizedifference/1gb)GB difference since $timetowaitinminutes minutes, no need to stop DFSR -ForegroundColor Green
} 