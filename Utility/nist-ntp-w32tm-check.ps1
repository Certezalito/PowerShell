# Scrape unique .gov NIST servers (exclude .edu, round robin, authenticated, and ut1) and query them via w32tm

# Scrape NIST servers
$servers = (Invoke-WebRequest https://tf.nist.gov/tf-cgi/servers.cgi)

# Convert to string and remove certain servers, ipv6 "::", control "nist.gov", authenticated "ntp-", misc urls "href", ut1 "ut1", 
$servers = $servers.tostring() -split "[`r`n]"  | Select-String -Pattern "::|control|ntp-|ut1|href|time.nist.gov" -NotMatch 

# Extracting domains from the output and only selecting the .gov servers
$servers = $servers -split ">|<" |  Select-String ".gov" 

# Remove duplicates 
$servers = $servers | select -Unique

# Iterate through the list and query them for data
foreach ($server in $servers)
{
Write-Host ==================== -ForegroundColor Yellow    
Write-Host $server -ForegroundColor Yellow 
Write-Host ==================== -ForegroundColor Yellow      
# Period must be >=5 seconds
w32tm /stripchart /computer:$server /dataonly /samples:10 /period:10
}