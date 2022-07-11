# Script to take a file and get all available hashes based on the available hashing algorithms listed in the help file 

# Get the file to hash 
$cessnawhat = Get-item 'S:\Downloads Browser\755506217547202751.webp'
# Get the available hashing algorithms from the help file
$algos = Get-Help Get-FileHash -Parameter algorithm | Out-String -Stream | Select-String "-"
# Parse the help file for all the available algorithms and feed them to get-filehash
$algos -match "- " -replace "    - " | foreach {Get-FileHash $cessnawhat -Algorithm $_ } | ft algorithm, hash -AutoSize
