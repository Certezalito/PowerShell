# Number of pages to fetch
$pages = 200
$waitSeconds = 15 # Number of seconds to wait between pages
$searchTerm = "ego power"
$baseUrl = "https://camelcamelcamel.com/top_drops/feed?bn=patio-lawn-garden&t=recent&"

for ($page = 1; $page -le $pages; $page++) {
    $url = "$baseUrl" + "p=$page"
    Write-Host "Fetching $url"
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing
        $xml = [xml]$response.Content
        $items = $xml.rss.channel.item
        $found = $false
        foreach ($item in $items) {
            $itemString = $item.OuterXml
            if ($itemString -match "(?i)$searchTerm") {
                if (-not $found) {
                    Write-Host "Found $searchTerm on page ${page}:"
                    $found = $true
                }
                Write-Host $itemString
            }
        }
    } catch {
        Write-Host "Failed to fetch $url"
    }
    Start-Sleep -Seconds $waitSeconds
}