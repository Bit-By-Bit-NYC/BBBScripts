# Get-EnterpriseAppUsage.ps1
# Script to enumerate Microsoft Enterprise Applications and determine usage

<#
.SYNOPSIS
    Enumerates Azure AD Enterprise Applications and analyzes their usage.

.DESCRIPTION
    This script retrieves all Enterprise Applications (Service Principals) from Azure AD
    and determines which ones are actively being used based on sign-in activity and user assignments.

.PREREQUISITES
    - Microsoft.Graph PowerShell module
    - Appropriate permissions: Application.Read.All, AuditLog.Read.All, Directory.Read.All, User.Read.All, Group.Read.All

.FEATURES
    - Resume capability: Stop/start without losing progress
    - Update mode: Quickly refresh user assignments (60x faster than full run)
    - Sign-in type breakdown: Interactive, Non-Interactive, Service Principal, Managed Identity
    - Detailed user assignment lists: See exactly who has access to each app

.EXAMPLE
    .\Get-EnterpriseAppUsage.ps1
    Runs the script with interactive prompts for mode selection (Full/Update/Resume)
    
.EXAMPLE
    .\Get-EnterpriseAppUsage.ps1
    # When prompted, choose [U] for UPDATE MODE to refresh user assignments only (fast!)
    # Choose [F] for FULL MODE to get complete sign-in analysis (slow but comprehensive)
    # Choose [R] to RESUME an interrupted run
#>

# Check if Microsoft.Graph module is installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "Microsoft.Graph module not found. Installing..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Import required modules
Import-Module Microsoft.Graph.Applications
Import-Module Microsoft.Graph.Reports
Import-Module Microsoft.Graph.Identity.SignIns

# Define checkpoint file path
$checkpointFile = Join-Path $PSScriptRoot "EnterpriseAppUsage_Checkpoint.json"
$updateMode = $false
$existingResults = $null

# Check for existing CSV files (most recent one)
$existingCsvFiles = Get-ChildItem -Path $PSScriptRoot -Filter "EnterpriseAppUsage_*.csv" -ErrorAction SilentlyContinue | 
    Sort-Object LastWriteTime -Descending | 
    Select-Object -First 1

# Check if we should offer update mode
if ($existingCsvFiles -or (Test-Path $checkpointFile)) {
    Write-Host "`n⚡ QUICK UPDATE MODE AVAILABLE" -ForegroundColor Yellow
    
    if ($existingCsvFiles) {
        Write-Host "Found existing CSV: $($existingCsvFiles.Name)" -ForegroundColor Cyan
        Write-Host "Last modified: $($existingCsvFiles.LastWriteTime)" -ForegroundColor Cyan
    }
    
    if (Test-Path $checkpointFile) {
        Write-Host "Found checkpoint file from in-progress run" -ForegroundColor Cyan
    }
    
    Write-Host "`nYou can:" -ForegroundColor White
    Write-Host "  [U] UPDATE - Just update user assignments (fast, ~10-20 minutes)" -ForegroundColor Green
    Write-Host "  [P] PERMISSIONS - Audit app permissions and assess risk (fast, ~15-25 minutes)" -ForegroundColor Magenta
    Write-Host "  [F] FULL - Run complete analysis with sign-in data (slow, ~12 hours)" -ForegroundColor Yellow
    Write-Host "  [R] RESUME - Resume from checkpoint (if available)" -ForegroundColor Cyan
    Write-Host "  [Q] QUIT - Exit script" -ForegroundColor Red
    
    $choice = Read-Host "`nYour choice (U/P/F/R/Q)"
    
    switch ($choice.ToUpper()) {
        'U' {
            Write-Host "`n✓ UPDATE MODE - Will only update user assignments" -ForegroundColor Green
            $updateMode = $true
            
            # Load existing data
            if ($existingCsvFiles) {
                Write-Host "Loading data from CSV: $($existingCsvFiles.FullName)" -ForegroundColor Cyan
                $existingResults = Import-Csv $existingCsvFiles.FullName
                Write-Host "Loaded $($existingResults.Count) existing records" -ForegroundColor Green
            }
            elseif (Test-Path $checkpointFile) {
                Write-Host "Loading data from checkpoint..." -ForegroundColor Cyan
                $checkpoint = Get-Content $checkpointFile -Raw | ConvertFrom-Json
                $existingResults = $checkpoint.Results
                Write-Host "Loaded $($existingResults.Count) existing records" -ForegroundColor Green
            }
        }
        'P' {
            Write-Host "`n✓ PERMISSIONS MODE - Will audit app permissions and assess risk" -ForegroundColor Magenta
            $permissionsMode = $true
            
            # Load permission risk database
            $scriptPath = $PSScriptRoot
            $riskDbPath = Join-Path $scriptPath "PermissionRiskDatabase.ps1"
            
            # Check if risk database exists, if not create it inline
            if (-not (Test-Path $riskDbPath)) {
                Write-Host "Loading permission risk database..." -ForegroundColor Cyan
                # Will be loaded inline below
            }
            
            # Load existing data if available
            if ($existingCsvFiles) {
                Write-Host "Loading data from CSV: $($existingCsvFiles.FullName)" -ForegroundColor Cyan
                $existingResults = Import-Csv $existingCsvFiles.FullName
                Write-Host "Loaded $($existingResults.Count) existing records" -ForegroundColor Green
            }
            elseif (Test-Path $checkpointFile) {
                Write-Host "Loading data from checkpoint..." -ForegroundColor Cyan
                $checkpoint = Get-Content $checkpointFile -Raw | ConvertFrom-Json
                $existingResults = $checkpoint.Results
                Write-Host "Loaded $($existingResults.Count) existing records" -ForegroundColor Green
            }
        }
        'R' {
            if (-not (Test-Path $checkpointFile)) {
                Write-Host "No checkpoint file found. Starting fresh run..." -ForegroundColor Yellow
            }
            # Will be handled by existing resume logic below
        }
        'Q' {
            Write-Host "Exiting..." -ForegroundColor Gray
            exit
        }
        'F' {
            Write-Host "`n✓ FULL MODE - Running complete analysis" -ForegroundColor Green
            # Continue with normal processing
        }
        default {
            Write-Host "Invalid choice. Running full analysis..." -ForegroundColor Yellow
        }
    }
}

# Connect to Microsoft Graph
Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.Read.All", "AuditLog.Read.All", "Directory.Read.All", "User.Read.All", "Group.Read.All", "DelegatedPermissionGrant.Read.All" -NoWelcome

Write-Host "Retrieving Enterprise Applications..." -ForegroundColor Cyan

# Get all Enterprise Applications (Service Principals)
$enterpriseApps = Get-MgServicePrincipal -All -Property "Id,AppId,DisplayName,CreatedDateTime,SignInAudience,Tags" `
    | Where-Object { $_.Tags -contains "WindowsAzureActiveDirectoryIntegratedApp" }

Write-Host "Found $($enterpriseApps.Count) Enterprise Applications" -ForegroundColor Green

# Handle UPDATE MODE - only update user assignments
if ($updateMode -and $existingResults) {
    Write-Host "`n=== UPDATE MODE: Refreshing User Assignments ===" -ForegroundColor Cyan
    Write-Host "This will be much faster than a full run...`n" -ForegroundColor Green
    
    $updateCounter = 0
    $updatedResults = @()
    
    # Create a hashtable for quick lookup by ApplicationId
    $existingLookup = @{}
    foreach ($existing in $existingResults) {
        $existingLookup[$existing.ApplicationId] = $existing
    }
    
    foreach ($app in $enterpriseApps) {
        $updateCounter++
        $percentComplete = [math]::Round(($updateCounter / $enterpriseApps.Count) * 100, 1)
        
        Write-Progress -Activity "Updating User Assignments" -Status "Processing $($app.DisplayName) ($updateCounter of $($enterpriseApps.Count))" `
            -PercentComplete $percentComplete
        
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-Host "[$timestamp] [$updateCounter/$($enterpriseApps.Count)] Updating: " -NoNewline -ForegroundColor Gray
        Write-Host $app.DisplayName -ForegroundColor Cyan
        
        # Get user assignments
        Write-Host "  → Fetching user assignments..." -NoNewline -ForegroundColor DarkGray
        $assignments = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $app.Id
        $assignedUserCount = $assignments.Count
        
        # Get list of assigned users/groups
        $assignedUsersList = @()
        foreach ($assignment in $assignments) {
            try {
                if ($assignment.PrincipalType -eq "User") {
                    $user = Get-MgUser -UserId $assignment.PrincipalId -Property DisplayName, UserPrincipalName -ErrorAction SilentlyContinue
                    if ($user) {
                        $assignedUsersList += "$($user.DisplayName) ($($user.UserPrincipalName))"
                    }
                }
                elseif ($assignment.PrincipalType -eq "Group") {
                    $group = Get-MgGroup -GroupId $assignment.PrincipalId -Property DisplayName -ErrorAction SilentlyContinue
                    if ($group) {
                        $assignedUsersList += "[Group] $($group.DisplayName)"
                    }
                }
                elseif ($assignment.PrincipalType -eq "ServicePrincipal") {
                    $sp = Get-MgServicePrincipal -ServicePrincipalId $assignment.PrincipalId -Property DisplayName -ErrorAction SilentlyContinue
                    if ($sp) {
                        $assignedUsersList += "[App] $($sp.DisplayName)"
                    }
                }
            }
            catch {
                $assignedUsersList += "$($assignment.PrincipalType): $($assignment.PrincipalId)"
            }
        }
        
        $assignedUsersString = $assignedUsersList -join "; "
        Write-Host " $assignedUserCount" -ForegroundColor Green
        
        # Check if we have existing data for this app
        if ($existingLookup.ContainsKey($app.AppId)) {
            # Update existing record
            $existingRecord = $existingLookup[$app.AppId]
            
            # Create updated object preserving all existing data
            $updatedRecord = [PSCustomObject]@{
                DisplayName                = $existingRecord.DisplayName
                ApplicationId              = $existingRecord.ApplicationId
                ObjectId                   = $existingRecord.ObjectId
                CreatedDate                = $existingRecord.CreatedDate
                AssignedUsers              = $assignedUserCount  # UPDATED
                AssignedUsersList          = $assignedUsersString  # UPDATED
                LastSignInDate             = $existingRecord.LastSignInDate
                DaysSinceLastSignIn        = $existingRecord.DaysSinceLastSignIn
                LastInteractiveSignIn      = $existingRecord.LastInteractiveSignIn
                DaysSinceLastInteractive   = $existingRecord.DaysSinceLastInteractive
                SignInsLast30Days          = $existingRecord.SignInsLast30Days
                InteractiveSignIns         = $existingRecord.InteractiveSignIns
                NonInteractiveSignIns      = $existingRecord.NonInteractiveSignIns
                ServicePrincipalSignIns    = $existingRecord.ServicePrincipalSignIns
                ManagedIdentitySignIns     = $existingRecord.ManagedIdentitySignIns
                UserEngagement             = $existingRecord.UserEngagement
                UsageStatus                = $existingRecord.UsageStatus
                SignInAudience             = $existingRecord.SignInAudience
            }
            
            Write-Host "  → Updated existing record" -ForegroundColor Green
        }
        else {
            # New app not in existing data - create minimal record
            $updatedRecord = [PSCustomObject]@{
                DisplayName                = $app.DisplayName
                ApplicationId              = $app.AppId
                ObjectId                   = $app.Id
                CreatedDate                = $app.CreatedDateTime
                AssignedUsers              = $assignedUserCount
                AssignedUsersList          = $assignedUsersString
                LastSignInDate             = "Not in previous run"
                DaysSinceLastSignIn        = "N/A"
                LastInteractiveSignIn      = "Not in previous run"
                DaysSinceLastInteractive   = "N/A"
                SignInsLast30Days          = "N/A"
                InteractiveSignIns         = "N/A"
                NonInteractiveSignIns      = "N/A"
                ServicePrincipalSignIns    = "N/A"
                ManagedIdentitySignIns     = "N/A"
                UserEngagement             = "Unknown"
                UsageStatus                = "Unknown"
                SignInAudience             = $app.SignInAudience
            }
            
            Write-Host "  → NEW app (not in previous run)" -ForegroundColor Yellow
        }
        
        $updatedResults += $updatedRecord
    }
    
    Write-Progress -Activity "Updating User Assignments" -Completed
    
    # Export updated results
    $exportPath = Join-Path $PSScriptRoot "EnterpriseAppUsage_Updated_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $updatedResults | Export-Csv -Path $exportPath -NoTypeInformation
    
    Write-Host "`n✓ UPDATE COMPLETE!" -ForegroundColor Green
    Write-Host "Updated $($updatedResults.Count) applications" -ForegroundColor White
    Write-Host "Results exported to: $exportPath" -ForegroundColor Green
    
    # Disconnect and exit
    Disconnect-MgGraph | Out-Null
    Write-Host "`nDisconnected from Microsoft Graph" -ForegroundColor Cyan
    exit
}

# Handle PERMISSIONS MODE - audit app permissions and assess risk
if ($permissionsMode) {
    Write-Host "`n=== PERMISSIONS MODE: Auditing App Permissions ===" -ForegroundColor Magenta
    Write-Host "This will analyze permissions and identify security risks...`n" -ForegroundColor Green
    
    # Load permission risk database inline
    . {
        $script:PermissionRiskDatabase = @{
            # Critical Risk
            "Directory.ReadWrite.All" = @{ Risk = "Critical"; Reason = "Full read/write access to entire directory"; Impact = "Complete tenant compromise possible" }
            "RoleManagement.ReadWrite.Directory" = @{ Risk = "Critical"; Reason = "Can assign admin roles including Global Admin"; Impact = "Privilege escalation to tenant admin" }
            "Application.ReadWrite.All" = @{ Risk = "Critical"; Reason = "Can create/modify applications and add credentials"; Impact = "Backdoor creation capability" }
            "AppRoleAssignment.ReadWrite.All" = @{ Risk = "Critical"; Reason = "Can grant any permission to any app"; Impact = "Privilege escalation for applications" }
            "UserAuthenticationMethod.ReadWrite.All" = @{ Risk = "Critical"; Reason = "Full control over user authentication methods"; Impact = "Can disable MFA, compromise accounts" }
            "Sites.FullControl.All" = @{ Risk = "Critical"; Reason = "Full control over all SharePoint sites"; Impact = "Complete SharePoint takeover" }
            
            # High Risk
            "Mail.ReadWrite.All" = @{ Risk = "High"; Reason = "Read and modify ALL mailboxes"; Impact = "Organization-wide email compromise" }
            "Mail.Send.All" = @{ Risk = "High"; Reason = "Send emails as any user"; Impact = "Organization-wide phishing capability" }
            "Files.ReadWrite.All" = @{ Risk = "High"; Reason = "Read and write all files"; Impact = "Data exfiltration, ransomware potential" }
            "Sites.ReadWrite.All" = @{ Risk = "High"; Reason = "Read and write all SharePoint sites"; Impact = "Organization-wide document compromise" }
            "User.ReadWrite.All" = @{ Risk = "High"; Reason = "Read and update all user profiles"; Impact = "User profile manipulation" }
            "Group.ReadWrite.All" = @{ Risk = "High"; Reason = "Read and write all groups"; Impact = "Privilege escalation via groups" }
            "Calendars.ReadWrite.All" = @{ Risk = "High"; Reason = "Read and write all calendars"; Impact = "Organization-wide schedule access" }
            "Mail.Read.All" = @{ Risk = "High"; Reason = "Read all mailboxes"; Impact = "Organization-wide email surveillance" }
            
            # Medium Risk
            "Mail.ReadWrite" = @{ Risk = "Medium"; Reason = "Read and modify user's mailbox"; Impact = "Email data exfiltration" }
            "Mail.Read" = @{ Risk = "Medium"; Reason = "Read user's email"; Impact = "Email content exposure" }
            "Files.Read.All" = @{ Risk = "Medium"; Reason = "Read all files user can access"; Impact = "Document data exfiltration" }
            "Directory.Read.All" = @{ Risk = "Medium"; Reason = "Read entire directory"; Impact = "Complete org visibility" }
            "User.Read.All" = @{ Risk = "Medium"; Reason = "Read all user profiles"; Impact = "Directory enumeration" }
            "Calendars.Read.All" = @{ Risk = "Medium"; Reason = "Read all calendars"; Impact = "Schedule visibility" }
            
            # Low Risk
            "User.Read" = @{ Risk = "Low"; Reason = "Read signed-in user's profile"; Impact = "Basic profile information" }
            "email" = @{ Risk = "Low"; Reason = "Read user's email address"; Impact = "Email address only" }
            "profile" = @{ Risk = "Low"; Reason = "Read user's basic profile"; Impact = "Basic profile information" }
            "openid" = @{ Risk = "Low"; Reason = "Sign in user"; Impact = "Authentication only" }
            "offline_access" = @{ Risk = "Low"; Reason = "Maintain access to data"; Impact = "Refresh token capability" }
        }
        
        function Get-PermissionRisk {
            param([string]$Permission)
            
            if ($script:PermissionRiskDatabase.ContainsKey($Permission)) {
                return $script:PermissionRiskDatabase[$Permission]
            }
            
            # Pattern matching
            if ($Permission -like "*.ReadWrite.All") {
                return @{ Risk = "High"; Reason = "Tenant-wide write access"; Impact = "Broad modification capability" }
            }
            if ($Permission -like "*.FullControl.All") {
                return @{ Risk = "Critical"; Reason = "Full control over resource"; Impact = "Complete resource control" }
            }
            if ($Permission -like "*.Read.All") {
                return @{ Risk = "Medium"; Reason = "Tenant-wide read access"; Impact = "Broad data visibility" }
            }
            
            return @{ Risk = "Unknown"; Reason = "Permission not in database"; Impact = "Review manually" }
        }
    }
    
    $permCounter = 0
    $permResults = @()
    
    foreach ($app in $enterpriseApps) {
        $permCounter++
        $percentComplete = [math]::Round(($permCounter / $enterpriseApps.Count) * 100, 1)
        
        Write-Progress -Activity "Auditing Permissions" -Status "Processing $($app.DisplayName) ($permCounter of $($enterpriseApps.Count))" `
            -PercentComplete $percentComplete
        
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-Host "[$timestamp] [$permCounter/$($enterpriseApps.Count)] Auditing: " -NoNewline -ForegroundColor Gray
        Write-Host $app.DisplayName -ForegroundColor Cyan
        
        # Get OAuth2 Permission Grants (Delegated Permissions)
        Write-Host "  → Checking delegated permissions..." -NoNewline -ForegroundColor DarkGray
        $delegatedPermissions = @()
        $delegatedPermsRaw = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $app.Id -ErrorAction SilentlyContinue
        
        foreach ($grant in $delegatedPermsRaw) {
            if ($grant.Scope) {
                $scopes = $grant.Scope.Split(' ') | Where-Object { $_ }
                foreach ($scope in $scopes) {
                    $risk = Get-PermissionRisk -Permission $scope
                    $delegatedPermissions += [PSCustomObject]@{
                        Permission = $scope
                        Type = "Delegated"
                        Risk = $risk.Risk
                        ConsentType = $grant.ConsentType
                    }
                }
            }
        }
        
        Write-Host " $($delegatedPermissions.Count) found" -ForegroundColor White
        
        # Get App Role Assignments (Application Permissions)
        Write-Host "  → Checking application permissions..." -NoNewline -ForegroundColor DarkGray
        $applicationPermissions = @()
        $appRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $app.Id -ErrorAction SilentlyContinue
        
        foreach ($assignment in $appRoleAssignments) {
            # Get the resource service principal to find the role name
            try {
                $resourceSP = Get-MgServicePrincipal -ServicePrincipalId $assignment.ResourceId -ErrorAction SilentlyContinue
                if ($resourceSP) {
                    $appRole = $resourceSP.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }
                    if ($appRole) {
                        $risk = Get-PermissionRisk -Permission $appRole.Value
                        $applicationPermissions += [PSCustomObject]@{
                            Permission = $appRole.Value
                            Type = "Application"
                            Risk = $risk.Risk
                            ResourceName = $resourceSP.DisplayName
                        }
                    }
                }
            }
            catch {
                # Skip if we can't resolve
            }
        }
        
        Write-Host " $($applicationPermissions.Count) found" -ForegroundColor White
        
        # Combine all permissions
        $allPermissions = $delegatedPermissions + $applicationPermissions
        
        # Calculate risk score
        $riskCounts = @{
            Critical = ($allPermissions | Where-Object { $_.Risk -eq "Critical" }).Count
            High = ($allPermissions | Where-Object { $_.Risk -eq "High" }).Count
            Medium = ($allPermissions | Where-Object { $_.Risk -eq "Medium" }).Count
            Low = ($allPermissions | Where-Object { $_.Risk -eq "Low" }).Count
            Unknown = ($allPermissions | Where-Object { $_.Risk -eq "Unknown" }).Count
        }
        
        # Determine overall risk level
        $overallRisk = if ($riskCounts.Critical -gt 0) { "Critical" }
            elseif ($riskCounts.High -gt 0) { "High" }
            elseif ($riskCounts.Medium -gt 0) { "Medium" }
            elseif ($riskCounts.Low -gt 0) { "Low" }
            else { "None" }
        
        # Create comma-separated list of critical/high permissions
        $criticalPermsList = ($allPermissions | Where-Object { $_.Risk -eq "Critical" } | Select-Object -ExpandProperty Permission) -join ", "
        $highPermsList = ($allPermissions | Where-Object { $_.Risk -eq "High" } | Select-Object -ExpandProperty Permission) -join ", "
        $allPermsList = ($allPermissions | Select-Object -ExpandProperty Permission) -join "; "
        
        Write-Host "  → Risk Assessment: " -NoNewline -ForegroundColor DarkGray
        switch ($overallRisk) {
            "Critical" { Write-Host $overallRisk -ForegroundColor Red -NoNewline; Write-Host " ($($riskCounts.Critical) critical)" -ForegroundColor Red }
            "High" { Write-Host $overallRisk -ForegroundColor DarkRed -NoNewline; Write-Host " ($($riskCounts.High) high)" -ForegroundColor DarkRed }
            "Medium" { Write-Host $overallRisk -ForegroundColor Yellow }
            "Low" { Write-Host $overallRisk -ForegroundColor Green }
            default { Write-Host $overallRisk -ForegroundColor Gray }
        }
        
        if ($criticalPermsList) {
            Write-Host "    └─ CRITICAL: $criticalPermsList" -ForegroundColor Red
        }
        if ($highPermsList) {
            Write-Host "    └─ HIGH: $highPermsList" -ForegroundColor DarkRed
        }
        
        Write-Host ""
        
        # Get existing record if available
        $existingRecord = if ($existingResults) {
            $existingResults | Where-Object { $_.ApplicationId -eq $app.AppId } | Select-Object -First 1
        } else { $null }
        
        # Create permission record
        $permRecord = [PSCustomObject]@{
            DisplayName = $app.DisplayName
            ApplicationId = $app.AppId
            ObjectId = $app.Id
            TotalPermissions = $allPermissions.Count
            DelegatedPermissions = $delegatedPermissions.Count
            ApplicationPermissions = $applicationPermissions.Count
            OverallRisk = $overallRisk
            CriticalPermissions = $riskCounts.Critical
            HighPermissions = $riskCounts.High
            MediumPermissions = $riskCounts.Medium
            LowPermissions = $riskCounts.Low
            CriticalPermissionsList = $criticalPermsList
            HighPermissionsList = $highPermsList
            AllPermissionsList = $allPermsList
            # Preserve existing data if available
            AssignedUsers = if ($existingRecord) { $existingRecord.AssignedUsers } else { "N/A" }
            AssignedUsersList = if ($existingRecord) { $existingRecord.AssignedUsersList } else { "N/A" }
            UserEngagement = if ($existingRecord) { $existingRecord.UserEngagement } else { "Unknown" }
            LastInteractiveSignIn = if ($existingRecord) { $existingRecord.LastInteractiveSignIn } else { "N/A" }
        }
        
        $permResults += $permRecord
    }
    
    Write-Progress -Activity "Auditing Permissions" -Completed
    
    # Display risk summary
    Write-Host "`n=== RISK SUMMARY ===" -ForegroundColor Magenta
    $criticalApps = ($permResults | Where-Object { $_.OverallRisk -eq "Critical" }).Count
    $highApps = ($permResults | Where-Object { $_.OverallRisk -eq "High" }).Count
    $mediumApps = ($permResults | Where-Object { $_.OverallRisk -eq "Medium" }).Count
    $lowApps = ($permResults | Where-Object { $_.OverallRisk -eq "Low" }).Count
    $noneApps = ($permResults | Where-Object { $_.OverallRisk -eq "None" }).Count
    
    Write-Host "Total Applications Audited: $($permResults.Count)" -ForegroundColor White
    Write-Host "Critical Risk: $criticalApps" -ForegroundColor Red
    Write-Host "High Risk: $highApps" -ForegroundColor DarkRed
    Write-Host "Medium Risk: $mediumApps" -ForegroundColor Yellow
    Write-Host "Low Risk: $lowApps" -ForegroundColor Green
    Write-Host "No Permissions: $noneApps" -ForegroundColor Gray
    
    # Export permissions report
    $permExportPath = Join-Path $PSScriptRoot "EnterpriseAppPermissions_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $permResults | Export-Csv -Path $permExportPath -NoTypeInformation
    
    Write-Host "`n✓ PERMISSIONS AUDIT COMPLETE!" -ForegroundColor Green
    Write-Host "Results exported to: $permExportPath" -ForegroundColor Green
    
    # Show top risky apps
    Write-Host "`n=== TOP 10 RISKIEST APPLICATIONS ===" -ForegroundColor Magenta
    $permResults | Sort-Object @{Expression={
        switch ($_.OverallRisk) {
            "Critical" { 4 }
            "High" { 3 }
            "Medium" { 2 }
            "Low" { 1 }
            default { 0 }
        }
    }}, CriticalPermissions, HighPermissions -Descending | 
    Select-Object -First 10 | 
    Format-Table DisplayName, OverallRisk, CriticalPermissions, HighPermissions, TotalPermissions -AutoSize
    
    # Disconnect and exit
    Disconnect-MgGraph | Out-Null
    Write-Host "`nDisconnected from Microsoft Graph" -ForegroundColor Cyan
    exit
}

# Initialize results array
$results = @()
$processedAppIds = @()
$resuming = $false

# Check if checkpoint file exists
if (Test-Path $checkpointFile) {
    Write-Host "`n⚠️  Checkpoint file found from previous run!" -ForegroundColor Yellow
    $checkpoint = Get-Content $checkpointFile -Raw | ConvertFrom-Json
    
    Write-Host "Previous run processed $($checkpoint.ProcessedCount) of $($checkpoint.TotalCount) apps" -ForegroundColor Cyan
    Write-Host "Last processed: $($checkpoint.LastProcessedApp)" -ForegroundColor Cyan
    
    $response = Read-Host "`nDo you want to RESUME from where you left off? (Y/N)"
    
    if ($response -eq 'Y' -or $response -eq 'y') {
        Write-Host "✓ Resuming from checkpoint..." -ForegroundColor Green
        $results = $checkpoint.Results
        $processedAppIds = $checkpoint.ProcessedAppIds
        $resuming = $true
        Write-Host "Loaded $($results.Count) previously processed apps" -ForegroundColor Green
    }
    else {
        Write-Host "Starting fresh. Deleting old checkpoint..." -ForegroundColor Yellow
        Remove-Item $checkpointFile -Force
    }
}

# Calculate date range for sign-in activity (last 30 days)
$startDate = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "Analyzing usage for each application..." -ForegroundColor Cyan
Write-Host "This may take several minutes for $($enterpriseApps.Count) applications...`n" -ForegroundColor Yellow
Write-Host "💡 TIP: You can press Ctrl+C to stop at any time. Progress is saved after each app." -ForegroundColor Green
Write-Host "       Run the script again to resume where you left off.`n" -ForegroundColor Green

$counter = if ($resuming) { $results.Count } else { 0 }
$totalProcessed = $counter
$inUseCounter = if ($resuming) { ($results | Where-Object { $_.UsageStatus -eq "In Use" }).Count } else { 0 }
$notInUseCounter = if ($resuming) { ($results | Where-Object { $_.UsageStatus -eq "Not In Use" }).Count } else { 0 }
$startTime = Get-Date
$appsToProcess = if ($resuming) { $enterpriseApps.Count - $results.Count } else { $enterpriseApps.Count }

if ($resuming) {
    Write-Host "Skipping $($results.Count) already processed apps...`n" -ForegroundColor Cyan
}

foreach ($app in $enterpriseApps) {
    # Skip if already processed
    if ($processedAppIds -contains $app.Id) {
        continue
    }
    
    $counter++
    $totalProcessed++
    $percentComplete = [math]::Round(($totalProcessed / $enterpriseApps.Count) * 100, 1)
    
    # Calculate estimated time remaining
    $elapsed = (Get-Date) - $startTime
    if ($counter -gt 0) {
        $avgTimePerApp = $elapsed.TotalSeconds / $counter
        $remainingApps = $appsToProcess - $counter
        $estimatedSecondsRemaining = $avgTimePerApp * $remainingApps
        $estimatedTimeRemaining = [TimeSpan]::FromSeconds($estimatedSecondsRemaining)
        $etaString = "{0:hh}h {0:mm}m {0:ss}s" -f $estimatedTimeRemaining
    }
    else {
        $etaString = "Calculating..."
    }
    
    Write-Progress -Activity "Analyzing Applications" -Status "Processing $($app.DisplayName) ($totalProcessed of $($enterpriseApps.Count)) - ETA: $etaString" `
        -PercentComplete $percentComplete
    
    # Console output with timestamp
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [$totalProcessed/$($enterpriseApps.Count)] Processing: " -NoNewline -ForegroundColor Gray
    Write-Host $app.DisplayName -ForegroundColor Cyan
    
    # Get user assignments
    Write-Host "  → Checking user assignments..." -NoNewline -ForegroundColor DarkGray
    $assignments = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $app.Id
    $assignedUserCount = $assignments.Count
    
    # Get list of assigned users/groups
    $assignedUsersList = @()
    foreach ($assignment in $assignments) {
        try {
            # Try to get user/group details
            if ($assignment.PrincipalType -eq "User") {
                $user = Get-MgUser -UserId $assignment.PrincipalId -Property DisplayName, UserPrincipalName -ErrorAction SilentlyContinue
                if ($user) {
                    $assignedUsersList += "$($user.DisplayName) ($($user.UserPrincipalName))"
                }
            }
            elseif ($assignment.PrincipalType -eq "Group") {
                $group = Get-MgGroup -GroupId $assignment.PrincipalId -Property DisplayName -ErrorAction SilentlyContinue
                if ($group) {
                    $assignedUsersList += "[Group] $($group.DisplayName)"
                }
            }
            elseif ($assignment.PrincipalType -eq "ServicePrincipal") {
                $sp = Get-MgServicePrincipal -ServicePrincipalId $assignment.PrincipalId -Property DisplayName -ErrorAction SilentlyContinue
                if ($sp) {
                    $assignedUsersList += "[App] $($sp.DisplayName)"
                }
            }
        }
        catch {
            # If we can't get details, just use the ID
            $assignedUsersList += "$($assignment.PrincipalType): $($assignment.PrincipalId)"
        }
    }
    
    # Join into semicolon-separated string for CSV compatibility
    $assignedUsersString = $assignedUsersList -join "; "
    
    Write-Host " Found $assignedUserCount" -ForegroundColor White
    if ($assignedUserCount -gt 0 -and $assignedUserCount -le 5) {
        Write-Host "    └─ Users: $assignedUsersString" -ForegroundColor DarkGray
    }
    elseif ($assignedUserCount -gt 5) {
        Write-Host "    └─ Users: $($assignedUsersList[0..4] -join ', ')... and $($assignedUserCount - 5) more" -ForegroundColor DarkGray
    }
    
    # Try to get sign-in activity
    Write-Host "  → Checking sign-in activity..." -NoNewline -ForegroundColor DarkGray
    $lastSignInDate = $null
    $signInCount = 0
    $hasRecentActivity = $false
    
    # Initialize sign-in type counters
    $interactiveSignIns = 0
    $nonInteractiveSignIns = 0
    $servicePrincipalSignIns = 0
    $managedIdentitySignIns = 0
    $lastInteractiveSignIn = $null
    
    try {
        # Note: This requires Azure AD Premium P1 or P2
        # Get ALL sign-in logs for this application in last 30 days
        $recentSignIns = Get-MgAuditLogSignIn -Filter "appId eq '$($app.AppId)' and createdDateTime ge $startDate" -All
        
        if ($recentSignIns) {
            # Get the most recent sign-in overall
            $lastSignInDate = ($recentSignIns | Sort-Object CreatedDateTime -Descending | Select-Object -First 1).CreatedDateTime
            $hasRecentActivity = $true
            
            # Count by sign-in type
            foreach ($signIn in $recentSignIns) {
                switch ($signIn.ClientCredentialType) {
                    "certificate" { $servicePrincipalSignIns++ }
                    "secret" { $servicePrincipalSignIns++ }
                    default {
                        # Check if it's a managed identity
                        if ($signIn.ServicePrincipalId -and $signIn.ResourceDisplayName -like "*Managed Identity*") {
                            $managedIdentitySignIns++
                        }
                        # Check if interactive
                        elseif ($signIn.IsInteractive) {
                            $interactiveSignIns++
                            if (-not $lastInteractiveSignIn) {
                                $lastInteractiveSignIn = $signIn.CreatedDateTime
                            }
                        }
                        else {
                            $nonInteractiveSignIns++
                        }
                    }
                }
            }
            
            $signInCount = $recentSignIns.Count
            
            # Display breakdown
            Write-Host " Total: $signInCount" -ForegroundColor Green
            Write-Host "    └─ Interactive: $interactiveSignIns | Non-Interactive: $nonInteractiveSignIns | Service Principal: $servicePrincipalSignIns | Managed Identity: $managedIdentitySignIns" -ForegroundColor DarkGray
            if ($lastInteractiveSignIn) {
                Write-Host "    └─ Last interactive: $($lastInteractiveSignIn.ToString('yyyy-MM-dd'))" -ForegroundColor Green
            }
        }
        else {
            Write-Host " No sign-ins found" -ForegroundColor Yellow
        }
    }
    catch {
        # Sign-in data unavailable (might not have Premium license or permissions)
        $lastSignInDate = "N/A"
        $signInCount = "N/A"
        $interactiveSignIns = "N/A"
        $nonInteractiveSignIns = "N/A"
        $servicePrincipalSignIns = "N/A"
        $managedIdentitySignIns = "N/A"
        $lastInteractiveSignIn = "N/A"
        Write-Host " Sign-in data unavailable" -ForegroundColor DarkYellow
    }
    
    # Determine usage status
    $usageStatus = if ($hasRecentActivity -or $assignedUserCount -gt 0) {
        $inUseCounter++
        "In Use"
    }
    elseif ($lastSignInDate -eq "N/A") {
        "Unknown (Sign-in data unavailable)"
    }
    else {
        $notInUseCounter++
        "Not In Use"
    }
    
    Write-Host "  → Status: " -NoNewline -ForegroundColor DarkGray
    if ($usageStatus -eq "In Use") {
        Write-Host $usageStatus -ForegroundColor Green
    }
    elseif ($usageStatus -eq "Not In Use") {
        Write-Host $usageStatus -ForegroundColor Red
    }
    else {
        Write-Host $usageStatus -ForegroundColor Yellow
    }
    Write-Host ""  # Blank line for readability
    
    # Calculate days since last sign-in
    $daysSinceLastSignIn = if ($lastSignInDate -and $lastSignInDate -ne "N/A") {
        [math]::Round(((Get-Date) - $lastSignInDate).TotalDays)
    }
    else {
        "N/A"
    }
    
    # Calculate days since last interactive sign-in
    $daysSinceLastInteractive = if ($lastInteractiveSignIn -and $lastInteractiveSignIn -ne "N/A") {
        [math]::Round(((Get-Date) - $lastInteractiveSignIn).TotalDays)
    }
    else {
        "N/A"
    }
    
    # Determine user engagement level
    $userEngagement = if ($interactiveSignIns -eq "N/A") {
        "Unknown"
    }
    elseif ($interactiveSignIns -gt 0) {
        "Active Users"
    }
    elseif ($nonInteractiveSignIns -gt 0 -or $servicePrincipalSignIns -gt 0 -or $managedIdentitySignIns -gt 0) {
        "Automated Only"
    }
    else {
        "No Activity"
    }
    
    # Create result object
    $result = [PSCustomObject]@{
        DisplayName                = $app.DisplayName
        ApplicationId              = $app.AppId
        ObjectId                   = $app.Id
        CreatedDate                = $app.CreatedDateTime
        AssignedUsers              = $assignedUserCount
        AssignedUsersList          = $assignedUsersString
        LastSignInDate             = $lastSignInDate
        DaysSinceLastSignIn        = $daysSinceLastSignIn
        LastInteractiveSignIn      = $lastInteractiveSignIn
        DaysSinceLastInteractive   = $daysSinceLastInteractive
        SignInsLast30Days          = $signInCount
        InteractiveSignIns         = $interactiveSignIns
        NonInteractiveSignIns      = $nonInteractiveSignIns
        ServicePrincipalSignIns    = $servicePrincipalSignIns
        ManagedIdentitySignIns     = $managedIdentitySignIns
        UserEngagement             = $userEngagement
        UsageStatus                = $usageStatus
        SignInAudience             = $app.SignInAudience
    }
    
    $results += $result
    $processedAppIds += $app.Id
    
    # Save checkpoint after each app
    $checkpointData = @{
        ProcessedCount = $totalProcessed
        TotalCount = $enterpriseApps.Count
        LastProcessedApp = $app.DisplayName
        LastProcessedTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Results = $results
        ProcessedAppIds = $processedAppIds
    }
    $checkpointData | ConvertTo-Json -Depth 10 | Set-Content $checkpointFile
    
    # Show interim summary every 50 apps
    if ($totalProcessed % 50 -eq 0 -and $totalProcessed -lt $enterpriseApps.Count) {
        Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "INTERIM SUMMARY - Processed $totalProcessed of $($enterpriseApps.Count) apps ($percentComplete%)" -ForegroundColor Cyan
        Write-Host "  In Use: $inUseCounter" -ForegroundColor Green
        Write-Host "  Not In Use: $notInUseCounter" -ForegroundColor Red
        Write-Host "  Unknown: $($totalProcessed - $inUseCounter - $notInUseCounter)" -ForegroundColor Yellow
        Write-Host "  Apps this session: $counter" -ForegroundColor White
        Write-Host "  Est. Time Remaining: $etaString" -ForegroundColor White
        Write-Host "  💾 Checkpoint saved - safe to stop" -ForegroundColor Green
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Cyan
    }
}

Write-Progress -Activity "Analyzing Applications" -Completed

# Clean up checkpoint file on successful completion
if (Test-Path $checkpointFile) {
    Remove-Item $checkpointFile -Force
    Write-Host "`n✓ Checkpoint file cleaned up (run completed successfully)" -ForegroundColor Green
}

# Display summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$inUse = ($results | Where-Object { $_.UsageStatus -eq "In Use" }).Count
$notInUse = ($results | Where-Object { $_.UsageStatus -eq "Not In Use" }).Count
$unknown = ($results | Where-Object { $_.UsageStatus -like "*Unknown*" }).Count

Write-Host "Total Applications: $($results.Count)" -ForegroundColor White
Write-Host "In Use: $inUse" -ForegroundColor Green
Write-Host "Not In Use: $notInUse" -ForegroundColor Yellow
Write-Host "Unknown Status: $unknown" -ForegroundColor Gray

# User Engagement breakdown
Write-Host "`n=== User Engagement ===" -ForegroundColor Cyan
$activeUsers = ($results | Where-Object { $_.UserEngagement -eq "Active Users" }).Count
$automatedOnly = ($results | Where-Object { $_.UserEngagement -eq "Automated Only" }).Count
$noActivity = ($results | Where-Object { $_.UserEngagement -eq "No Activity" }).Count
$unknownEngagement = ($results | Where-Object { $_.UserEngagement -eq "Unknown" }).Count

Write-Host "Active Users (Interactive sign-ins): $activeUsers" -ForegroundColor Green
Write-Host "Automated Only (No user sign-ins): $automatedOnly" -ForegroundColor Yellow
Write-Host "No Activity: $noActivity" -ForegroundColor Red
Write-Host "Unknown: $unknownEngagement" -ForegroundColor Gray

# Display results in console
Write-Host "`n=== Applications ===" -ForegroundColor Cyan
$results | Sort-Object UserEngagement, DisplayName | Format-Table DisplayName, UserEngagement, InteractiveSignIns, ServicePrincipalSignIns, LastInteractiveSignIn, AssignedUsers -AutoSize

# Export to CSV
$exportPath = Join-Path $PSScriptRoot "EnterpriseAppUsage_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $exportPath -NoTypeInformation
Write-Host "`nResults exported to: $exportPath" -ForegroundColor Green

# Disconnect from Microsoft Graph
Disconnect-MgGraph | Out-Null
Write-Host "`nDisconnected from Microsoft Graph" -ForegroundColor Cyan
