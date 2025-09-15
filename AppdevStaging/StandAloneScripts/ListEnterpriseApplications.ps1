# Connect to Microsoft Graph with necessary scopes
Connect-MgGraph -Scopes "Application.Read.All", "Directory.Read.All"

# Get all service principals (Enterprise Applications)
$servicePrincipals = Get-MgServicePrincipal -All

$results = @()

foreach ($sp in $servicePrincipals) {
    Write-Host "🔍 Processing: $($sp.DisplayName)" -ForegroundColor Cyan

    # Get delegated permissions (OAuth2PermissionGrants)
    $oauthGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue

    # Get app role assignments (application permissions)
    $appRoles = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue

    $entry = [PSCustomObject]@{
        AppName              = $sp.DisplayName
        AppId                = $sp.AppId
        ObjectId             = $sp.Id
        DelegatedPermissions = ($oauthGrants | ForEach-Object { "$($_.ResourceDisplayName): $($_.Scope)" }) -join "; "
        AppRoleAssignments   = ($appRoles | ForEach-Object { "$($_.ResourceDisplayName): $($_.AppRoleId)" }) -join "; "
    }

    $results += $entry
}

# Output to console and CSV
$results | Format-Table -AutoSize
$results | Export-Csv "EnterpriseApps_Permissions.csv" -NoTypeInformation