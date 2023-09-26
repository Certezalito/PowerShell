$servers = @("tick.usno.navy.mil","tock.usno.navy.mil","ntp2.usno.navy.mil","tick.usnogps.navy.mil","tock.usnogps.navy.mil")


# Iterate through the list and query them for data
foreach ($server in $servers)
{
Write-Host ==================== -ForegroundColor Yellow    
Write-Host $server -ForegroundColor Yellow 
Write-Host ==================== -ForegroundColor Yellow      
# Period must be >=5 seconds
w32tm /stripchart /computer:$server /dataonly /samples:10 /period:10
}