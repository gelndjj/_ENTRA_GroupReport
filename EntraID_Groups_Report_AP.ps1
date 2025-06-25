#Connect to Microsoft Graph
Connect-MgGraph -Scopes "Group.Read.All", "GroupMember.Read.All", "RoleManagement.Read.Directory", "Application.Read.All", "Policy.Read.All", "User.Read.All"

# Define CSV columns
$CSVProperties = @(
    "Object ID", "Display Name", "Group Type", "Group Email", "Mail Enabled", "Is Teams Team",
    "Membership Type", "Dynamic Rule", "Visibility", "Created On", "Description",
    "Assigned Owners", "Total Members", "Nested Groups",
    "Referenced In CA Policy Include", "Referenced In CA Policy Exclude",
    "Assigned Roles", "Referenced in App Roles","Referenced in Access Packages"
)

# Function to batch Graph requests
function Send-MgGraphBatchRequests {
    param (
        [Parameter(Mandatory)] $requests,
        [Parameter()] [ValidateSet('beta','v1.0')] $Apiversion = 'v1.0',
        [int] $batchSize = 20
    )

    $batches = [System.Collections.Generic.List[pscustomobject]]::new()
    $responses = [System.Collections.Concurrent.ConcurrentBag[System.Object]]::new()

    for ($i = 0; $i -lt $requests.Count; $i += $batchSize) {
        $end = [math]::Min($i + $batchSize - 1, $requests.Count - 1)
        $batches.Add(@{
            'Method'      = 'Post'
            'Uri'         = "https://graph.microsoft.com/$Apiversion/`$batch"
            'ContentType' = 'application/json'
            'Body'        = @{ 'requests' = @($requests[$i..$end]) } | ConvertTo-Json -Depth 5
        })
    }

    $batches | ForEach-Object {
        $result = Invoke-MgGraphRequest @_ 
        foreach ($r in $result.responses) {
            $responses.Add([pscustomobject]@{
                requestid   = $r.id.Split(":")[0]
                requesttype = $r.id.Split(":")[1]
                body        = $r.body
                error       = $r.error
            })
        }
    }

    return $responses
}

$scriptStart = Get-Date
Write-Host "[+] Retrieving all groups..."
$timerGroups = [System.Diagnostics.Stopwatch]::StartNew()
$groups = Get-MgGroup -All -Property "Id", "DisplayName", "GroupTypes", "Mail", "MailEnabled", "Visibility", "CreatedDateTime", "Description", "MembershipRule", "MembershipRuleProcessingState"
$timerGroups.Stop()

Write-Host "[+] Retrieving Teams-enabled groups..."
$teamsGroupIds = (Get-MgGroup -All -Filter "resourceProvisioningOptions/Any(x:x eq 'Team')" -Property "Id").Id

Write-Host "[+] Retrieving Conditional Access policies and role assignments..."
$caPolicies = Get-MgIdentityConditionalAccessPolicy -All
$roleAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All
$roleDefinitions = Get-MgRoleManagementDirectoryRoleDefinition -All

Write-Host "[+] Retrieving Access packages..."
$AccessPackages = Get-MgEntitlementManagementAccessPackage -All



Write-Host "[+] Sending Graph batch requests..."
$timerBatch = [System.Diagnostics.Stopwatch]::StartNew()
$requests = [System.Collections.Generic.List[object]]::new()
foreach ($group in $groups) {
    $requests.Add(@{ id = "$($group.Id):members"; method = "GET"; url = "/groups/$($group.Id)/members?`$count=true"; headers = @{ "ConsistencyLevel" = "eventual" } })
    $requests.Add(@{ id = "$($group.Id):owners"; method = "GET"; url = "/groups/$($group.Id)/owners" })
    $requests.Add(@{ id = "$($group.Id):nested"; method = "GET"; url = "/groups/$($group.Id)/members" })
    $requests.Add(@{ id = "$($group.Id):approle"; method = "GET"; url = "/groups/$($group.Id)/appRoleAssignments" })
}
foreach ($ap in $AccessPackages){
    $requests.Add(@{ id = "$($ap.Id):packageressource"; method = "GET"; url = `
        "/identityGovernance/entitlementManagement/accessPackages/$($ap.id)?`$expand=accessPackageResourceRoleScopes(`$expand=accessPackageResourceScope)"})

}

$responsesList = Send-MgGraphBatchRequests -requests $requests -Apiversion 'beta'
$responses = $responsesList | Group-Object -Property requestid -AsHashTable
$timerBatch.Stop()

Write-Host "[+] Processing data and building report..."
$timerProcess = [System.Diagnostics.Stopwatch]::StartNew()

$accessPackagesReferences = @{}
foreach ($ap in $AccessPackages) {
    $id = $ap.Id
    if ($responses.ContainsKey($id)) {
        $packagegroups = ($responses[$id] | Where-Object {$_.requesttype -eq "packageressource"}).body.accessPackageResourceRoleScopes
        foreach($packagegroup in $packagegroups){
            $groupId = $packagegroup.accessPackageResourceScope.originId
            if ($accessPackagesReferences.ContainsKey($groupId)) {
                $accessPackagesReferences[$groupId] += ", $($ap.DisplayName)"
            } else {
                $accessPackagesReferences[$groupId] = $ap.DisplayName
            }
        }
    }
}

foreach ($group in $groups) {
    $id = $group.Id

    $group | Add-Member -NotePropertyName "Object ID" -NotePropertyValue $id -Force
    $group | Add-Member -NotePropertyName "Display Name" -NotePropertyValue $group.DisplayName -Force

    # Friendly Group Type label
    $baseType = if ($group.GroupTypes -contains "Unified") { "Microsoft365" } else { "Security" }
    $group | Add-Member -NotePropertyName "Group Type" -NotePropertyValue $baseType -Force

    $group | Add-Member -NotePropertyName "Group Email" -NotePropertyValue $group.Mail -Force
    $group | Add-Member -NotePropertyName "Mail Enabled" -NotePropertyValue $group.MailEnabled -Force
    $group | Add-Member -NotePropertyName "Is Teams Team" -NotePropertyValue ($teamsGroupIds -contains $id) -Force
    $group | Add-Member -NotePropertyName "Membership Type" -NotePropertyValue ($group.MembershipRuleProcessingState -ne $null ? "Dynamic" : "Assigned") -Force
    $group | Add-Member -NotePropertyName "Dynamic Rule" -NotePropertyValue $group.MembershipRule -Force
    $group | Add-Member -NotePropertyName "Visibility" -NotePropertyValue $group.Visibility -Force
    $group | Add-Member -NotePropertyName "Created On" -NotePropertyValue $group.CreatedDateTime -Force
    $group | Add-Member -NotePropertyName "Description" -NotePropertyValue $group.Description -Force

    if ($responses.ContainsKey($id)) {
        $groupResponses = $responses[$id]
        $owners = $groupResponses | Where-Object { $_.requesttype -eq "owners" }
        $members = $groupResponses | Where-Object { $_.requesttype -eq "members" }
        $nested = $groupResponses | Where-Object { $_.requesttype -eq "nested" }
        $approles = $groupResponses | Where-Object { $_.requesttype -eq "approle" }

        $ownersNames = ($owners.body.value | ForEach-Object { $_.displayName }) -join ", "
        $nestedNames = ($nested.body.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | ForEach-Object { $_.displayName }) -join ", "
        $approlesName = ($approles.body.value.resourceDisplayName) -join ", "


        $group | Add-Member -NotePropertyName "Assigned Owners" -NotePropertyValue $ownersNames -Force
        $group | Add-Member -NotePropertyName "Total Members" -NotePropertyValue $($members.body.'@odata.count') -Force
        $group | Add-Member -NotePropertyName "Nested Groups" -NotePropertyValue $nestedNames -Force
        $group | Add-Member -NotePropertyName "Referenced in App Roles" -NotePropertyValue $approlesName -Force
    } else {
        $group | Add-Member -NotePropertyName "Assigned Owners" -NotePropertyValue "" -Force
        $group | Add-Member -NotePropertyName "Total Members" -NotePropertyValue 0 -Force
        $group | Add-Member -NotePropertyName "Nested Groups" -NotePropertyValue "" -Force
        $group | Add-Member -NotePropertyName "Referenced in App Roles" -NotePropertyValue "" -Force
    }


    $includedCAPolicies = ($caPolicies | Where-Object { $_.Conditions.Users.IncludeGroups -contains $id }).DisplayName -join ", "
    $excludedCAPolicies = ($caPolicies | Where-Object { $_.Conditions.Users.ExcludeGroups -contains $id }).DisplayName -join ", "
    $group | Add-Member -NotePropertyName "Referenced In CA Policy Include" -NotePropertyValue $includedCAPolicies -Force
    $group | Add-Member -NotePropertyName "Referenced In CA Policy Exclude" -NotePropertyValue $excludedCAPolicies -Force

    $assignedRoleIds = ($roleAssignments | Where-Object { $_.PrincipalId -eq $id }).RoleDefinitionId
    $assignedRoles = ($roleDefinitions | Where-Object { $assignedRoleIds -contains $_.Id }).DisplayName -join ", "
    $group | Add-Member -NotePropertyName "Assigned Roles" -NotePropertyValue $assignedRoles -Force

    $group | Add-Member -NotePropertyName "Referenced in Access Packages" -NotePropertyValue $($accessPackagesReferences[$id]) -Force
}
$timerProcess.Stop()

# Export to CSV
Write-Host "[+] Writing output to CSV..."
$outputPath = "EntraID_Groups_Report_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date)
$groups | Select-Object -Property $CSVProperties | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8

$scriptEnd = Get-Date

Write-Host "---"
Write-Host "[✓] Done. Report saved to: $outputPath"
Write-Host "[i] Time elapsed:"
Write-Host "   - Group retrieval:       $($timerGroups.Elapsed.ToString())"
Write-Host "   - Batch API requests:    $($timerBatch.Elapsed.ToString())"
Write-Host "   - Processing responses:  $($timerProcess.Elapsed.ToString())"
Write-Host "   - Total execution:       $($scriptEnd - $scriptStart)"