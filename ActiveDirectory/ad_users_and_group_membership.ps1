# Script to get Active Directory Groups and Users based on Group Members as the system group membership like "Domain Users" does not show up from get-aduser -properties memberof

# Import Active Directory module
Import-Module ActiveDirectory

# Get domain information 
$domain = Get-ADDomain

# Location to store the CSV and name of CSV
$path = "C:\temp\$($domain.name)_ad_users_and_their_group_membership_$(Get-Date -Format "MM-dd-yyyy").csv"

# Get Active Directory Groups and Active Diretory Users
$groups = Get-ADGroup -Filter *
$users = Get-ADUser -Filter *  -Properties description

# Declare Empty Hash Table for Group Membership
$memberhash = @{}
# Declare Empty Hash Table for Final CSV Output
$grouphash = @{}
# Declare Empty Array for final output
$finaloutput = @()
# Declare Empty Hash Table for user enabled query
$userenabled = @{}

# Iterate through all the Active Directory Groups and store their membership in a hash table
foreach ($groups in $groups)
{
    # Get Group Membership of single group 
    $members = Get-ADGroupMember -Identity $groups 
    
    # Store each Active Directory Group Name and Active Directory Group Membership in a hash table
    $memberhash.add($groups.name,$members.samaccountname)
}

# Iterate through all the Active Directory Users and check their Active Directory Group Membership from the group membership hash table
foreach ($users in $users)
{
    # Check a user against their group membership from the group membership hash table     
    $groupmembership = ($memberhash.GetEnumerator() |  ? {$_.value -eq $users.samaccountname }).name 

    # query user enabled and store into hash table
    $userenabled.add($users.samaccountname,$users.Enabled)
  
    # Add group membership to hash table
    $grouphash.Add($users.samaccountname,$groupmembership) 
}

# Iterate through each user in the userenabled hash table and store enabled, group membership in array
 foreach($key in $userenabled.keys) {
    # Declare empty object for loop use
    $output = New-Object PSObject
     
    # Add SamAccountName to array
    $output | Add-Member -Name 'SamAccountName' -Value $key -Type NoteProperty
    
    # Query enabled status and add to array 
    $userenabledstatus = ($userenabled.GetEnumerator() | ? {$_.key -eq $key} | Select-Object value).value
    $output | Add-Member -Name 'Enabled' -Value $userenabledstatus -Type NoteProperty
    
    # Query MemberOf and add to array
    $output | Add-Member -Name 'MemberOf' -Value $($grouphash[$key] -join ', ') -Type NoteProperty
    
    # Add to final array before loop and reset
    $finaloutput += $output
}

# Sort final table by SamAccountName
$finaloutput = $finaloutput | Sort-Object SamAccountName
# Export to CSV
$finaloutput  | Export-Csv -Path $path 

# Screen Output
# Count users and output to screen
$count = ($userenabled.GetEnumerator() | measure).count
Write-host "Total User accounts:" $count -ForegroundColor Yellow
# Notify saved csv location
Write-Host "Exported CSV:" $path -ForegroundColor Yellow