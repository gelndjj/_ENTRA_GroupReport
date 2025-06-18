$duration = Measure-Command {

    Connect-MgGraph -Scopes "Group.Read.All", "GroupMember.Read.All", "Team.ReadBasic.All", "Policy.Read.All", "Application.Read.All"

    function Split-ToChunks {
        param (
            [Parameter(Mandatory)][array]$InputArray,
            [int]$ChunkSize = 20
        )
        for ($i = 0; $i -lt $InputArray.Count; $i += $ChunkSize) {
            $InputArray[$i..([math]::Min($i + $ChunkSize - 1, $InputArray.Count - 1))]
        }
    }

    $groupReports = @()
    $memberCounts = @{}
    $ownerNamesMap = @{}

    $allGroups = Get-MgGroup -All -Property "Id", "DisplayName", "GroupTypes", "Mail", "MailEnabled", "Description", "Visibility", "CreatedDateTime", "MembershipRule", "ResourceProvisioningOptions"
    $groupIds = $allGroups.Id

    foreach ($groupChunk in Split-ToChunks -InputArray $groupIds) {
        $requests = @()
        foreach ($groupId in $groupChunk) {
            $requests += @{
                id     = "members_$groupId"
                method = "GET"
                url    = "/groups/$groupId/members?$top=1"
            }
        }

        try {
            $batchBody = @{ requests = $requests }
            $batchResponse = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/`$batch" -Body $batchBody

            foreach ($resp in $batchResponse.responses) {
                $id = $resp.id -replace "^members_", ""
                $memberCounts[$id] = if ($resp.status -eq 200) { $resp.body.value.Count } else { "Error" }
            }
        } catch {
            Write-Warning "Batch members failed: $_"
        }
    }

    foreach ($groupChunk in Split-ToChunks -InputArray $groupIds) {
        $requests = @()
        foreach ($groupId in $groupChunk) {
            $requests += @{
                id     = "owners_$groupId"
                method = "GET"
                url    = "/groups/$groupId/owners"
            }
        }

        try {
            $batchBody = @{ requests = $requests }
            $batchResponse = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/`$batch" -Body $batchBody

            foreach ($resp in $batchResponse.responses) {
                $id = $resp.id -replace "^owners_", ""
                $ownerNamesMap[$id] = if ($resp.status -eq 200) {
                    ($resp.body.value | ForEach-Object { $_.displayName }) -join "; "
                } else {
                    "Error"
                }
            }
        } catch {
            Write-Warning "Batch owners failed: $_"
        }
    }

    $caPolicies = Get-MgIdentityConditionalAccessPolicy -All

    $roleAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All
    $roleDefinitions = Get-MgRoleManagementDirectoryRoleDefinition -All

    $roleDefMap = @{}
    foreach ($def in $roleDefinitions) {
        $roleDefMap[$def.Id] = $def.DisplayName
    }

    $groupIdToRoles = @{}
    foreach ($ra in $roleAssignments) {
        if ($ra.PrincipalId -and $roleDefMap.ContainsKey($ra.RoleDefinitionId)) {
            $roleName = $roleDefMap[$ra.RoleDefinitionId]
            if (-not $groupIdToRoles.ContainsKey($ra.PrincipalId)) {
                $groupIdToRoles[$ra.PrincipalId] = @()
            }
            $groupIdToRoles[$ra.PrincipalId] += $roleName
        }
    }

    # === FETCH APP ROLE ASSIGNMENTS FOR ALL SERVICE PRINCIPALS ===
    $groupAppRoleMap = @{}
    $servicePrincipals = Get-MgServicePrincipal -All

    foreach ($sp in $servicePrincipals) {
        try {
            $assignments = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction Stop
            foreach ($a in $assignments) {
                if ($a.PrincipalType -eq "Group") {
                    if (-not $groupAppRoleMap.ContainsKey($a.PrincipalId)) {
                        $groupAppRoleMap[$a.PrincipalId] = @()
                    }
                    $groupAppRoleMap[$a.PrincipalId] += $a.ResourceDisplayName
                }
            }
        } catch {
            Write-Verbose "Failed to get app roles for SP $($sp.DisplayName): $_"
        }
    }

    # === FETCH NESTED GROUPS ===
    $groupIdToNestedGroups = @{}

    foreach ($groupChunk in Split-ToChunks -InputArray $groupIds) {
        $requests = @()

        foreach ($groupId in $groupChunk) {
            $requests += @{
                id     = "members_$groupId"
                method = "GET"
                url    = "/groups/$groupId/members"
            }
        }

        try {
            $batchBody = @{ requests = $requests }
            $batchResponse = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/`$batch" -Body $batchBody

            foreach ($resp in $batchResponse.responses) {
                $id = $resp.id -replace "^members_", ""
                if ($resp.status -eq 200) {
                    $nested = $resp.body.value | Where-Object { $_.'@odata.type' -eq "#microsoft.graph.group" }
                    $names = $nested | ForEach-Object { $_.displayName }
                    $groupIdToNestedGroups[$id] = ($names -join ", ")
                } else {
                    $groupIdToNestedGroups[$id] = ""
                }
            }
        } catch {
            Write-Warning "Batch nested group detection failed: $_"
        }
    }

    foreach ($group in $allGroups) {
        $groupId        = $group.Id
        $displayName    = $group.DisplayName
        $groupType      = if ($group.GroupTypes -contains "Unified") { "Microsoft 365" } else { "Security" }
        $membershipType = if ($group.MembershipRule) { "Dynamic" } else { "Static" }
        $dynamicRule    = $group.MembershipRule
        $groupEmail     = $group.Mail
        $description    = $group.Description
        $visibility     = $group.Visibility
        $createdOn      = $group.CreatedDateTime
        $mailEnabled    = $group.MailEnabled
        $memberCount    = $memberCounts[$groupId]
        $ownerNames     = $ownerNamesMap[$groupId]
        $nestedGroups = if ($groupIdToNestedGroups.ContainsKey($groupId)) {
        $groupIdToNestedGroups[$groupId]
        } else {
            ""
        }
        # Get all M365 groups that are Teams Teams
        $teamsGroups = Get-MgGroup -All -Filter "resourceProvisioningOptions/Any(x:x eq 'Team')" -Select "Id"
        $teamsGroupIds = $teamsGroups.Id

        # Then later in the loop:
        $isTeam = if ($group.GroupTypes -contains "Unified") {
            if ($group.Id -in $teamsGroupIds) { "Yes" } else { "No" }
        } else {
            "N/A"
        }

        $caInclude = ($caPolicies | Where-Object { $_.Conditions.Users.IncludeGroups -contains $groupId }).DisplayName -join ", "
        $caExclude = ($caPolicies | Where-Object { $_.Conditions.Users.ExcludeGroups -contains $groupId }).DisplayName -join ", "
        $assignedRoles = if ($groupIdToRoles.ContainsKey($groupId)) {
            ($groupIdToRoles[$groupId] | Sort-Object -Unique) -join ", "
        } else {
            ""
        }
        $referencedApps = if ($groupAppRoleMap.ContainsKey($groupId)) {
            ($groupAppRoleMap[$groupId] | Sort-Object -Unique) -join ", "
        } else {
            ""
        }

        $groupReports += [PSCustomObject]@{
            "Object ID"                    = $groupId
            "Display Name"                 = $displayName
            "Group Type"                   = $groupType
            "Group Email"                  = $groupEmail
            "Mail Enabled"                 = $mailEnabled
            "Is Teams Team"                = $isTeam
            "Membership Type"              = $membershipType
            "Dynamic Rule"                 = $dynamicRule
            "Visibility"                   = $visibility
            "Created On"                   = $createdOn
            "Description"                  = $description
            "Assigned Owners"              = $ownerNames
            "Total Members"                = $memberCount
            "Nested Groups"                = $nestedGroups
            "Referenced In CA Policy Include"   = if ($caInclude) { $caInclude } else { "" }
            "Referenced In CA Policy Exclude"   = if ($caExclude) { $caExclude } else { "" }
            "Assigned Roles"               = $assignedRoles
            "Referenced in App Roles"      = $referencedApps
        }
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $csvPath = "EntraID_Groups_Report_$timestamp.csv"
    $groupReports | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    Write-Host "Exported to: $csvPath" -ForegroundColor Green
}

Write-Host "Elapsed time: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor Cyan
