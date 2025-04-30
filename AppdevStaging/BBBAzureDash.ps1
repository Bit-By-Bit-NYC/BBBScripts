# ==================================================================
# Script: Tenant Health Dashboard for BBB Service Principal Apps
# Author: ChatGPT + Jim Collaboration
# Date: 2025-04-28
# ==================================================================

# --- CONFIGURATION ---

# Service Principal Client ID
$ClientId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1"

# App Names to Check
$appNames = @("BBB MS Licensing", "BBB MS Reboot", "BBB MS Patch")

# --- MANUALLY BUILT TENANTS LIST ---
$tenants = @{
    "1" = @{ Name = "Bit By Bit Computer Consultants"; Id = "27f318ae-79fe-4219-aa14-689300d7365c" }
    "2" = @{ Name = "SeniorCare"; Id = "6e35e8df-159a-4d3a-8d09-687ad995e311" }
    "3" = @{ Name = "Daniel H Cook and Associates"; Id = "6a56dc62-92c4-461a-b932-bb35887b2c80" }
    # Add rest of your tenants here...
}

# --- USER PROMPT FOR CLIENT SECRET ---
$PlainClientSecret = Read-Host "Enter client secret for the Service Principal"

Write-Host "`nAuthenticating with Azure CLI (Service Principal)..."

# --- RESULTS HOLDER ---
$results = @()

# --- MAIN LOOP ---
foreach ($key in ($tenants.Keys | Sort-Object)) {
    $tenant = $tenants[$key]
    Write-Host "\nChecking Tenant: $($tenant.Name) ($($tenant.Id))..." -ForegroundColor Cyan


    # Connect to Microsoft Graph
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue

        # Explicit login to each tenant
        az logout | Out-Null

        $azLogin = az login --service-principal -u $ClientId -p $PlainClientSecret --tenant $($tenant.Id) --allow-no-subscriptions | ConvertFrom-Json

        if (-not $azLogin) {
            throw "Failed Azure CLI login for $($tenant.Name)"
        }

        # Get access token after logging in
        $accessToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv

        if (-not $accessToken) {
            throw "Failed to retrieve access token for $($tenant.Name)"
        }

        $secureToken = ConvertTo-SecureString -String $accessToken -AsPlainText -Force
        Connect-MgGraph -AccessToken $secureToken -NoWelcome

        Write-Host "Connected successfully to $($tenant.Name)" -ForegroundColor Green
        $connected = $true
    }
    catch {
        Write-Host "❌ Failed to connect to $($tenant.Name)" -ForegroundColor Red
        Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor Yellow
        $connected = $false
    }

    # Initialize checks
    $licenseStatus = "N/A"
    $licensingApp = "N/A"
    $rebootApp = "N/A"
    $patchApp = "N/A"
    $overallStatus = "❌ Error"

    if ($connected) {
        try {
            # Test licensing access (Get-MgUser)
            $testUser = Get-MgUser -Top 1 -ErrorAction Stop
            $licenseStatus = "🟢"
        }
        catch {
            $licenseStatus = "🔴"
        }

        # Check permission claims from context
        $appHealth = @{
            LicensingApp = "❌"
            RebootApp    = "❌"
            PatchApp     = "❌"
        }

        try {
            $context = Get-MgContext
            $scopes = $context.Scopes

            Write-Host "`n🔍 DEBUG: Connected to $($tenant.Name)" -ForegroundColor Yellow
            Write-Host "Scopes in context:" -ForegroundColor Yellow
            $scopes | ForEach-Object { Write-Host " - $_" -ForegroundColor DarkYellow }

            if ("Directory.Read.All" -in $scopes) { $appHealth["LicensingApp"] = "🟢" }
            if ("AuditLog.Read.All" -in $scopes) {
                $appHealth["RebootApp"] = "🟢"
                $appHealth["PatchApp"] = "🟢"
            }
        }
        catch {
            Write-Host "⚠️ Could not retrieve context scopes in $($tenant.Name)" -ForegroundColor Yellow
        }
        $licensingApp = $appHealth["LicensingApp"]
        $rebootApp    = $appHealth["RebootApp"]
        $patchApp     = $appHealth["PatchApp"]

        # Determine overall status
        if ($licenseStatus -eq "🟢" -and $licensingApp -eq "🟢" -and $rebootApp -eq "🟢" -and $patchApp -eq "🟢") {
            $overallStatus = "✅ OK"
        } elseif ($licenseStatus -eq "🟢" -or $licensingApp -eq "🟢" -or $rebootApp -eq "🟢" -or $patchApp -eq "🟢") {
            $overallStatus = "⚠️ Partial"
        } else {
            $overallStatus = "❌ Error"
        }
    }

    # Store results
    $results += [PSCustomObject]@{
        TenantName    = $tenant.Name
        LicensingAPI  = $licenseStatus
        LicensingApp  = $licensingApp
        RebootApp     = $rebootApp
        PatchApp      = $patchApp
        OverallHealth = $overallStatus
    }
}

# --- DISPLAY RESULTS ---
Write-Host "\n\nTenant Health Dashboard:" -ForegroundColor Green
$results | Format-Table -AutoSize

# --- EXPORT RESULTS ---
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmm")
$csvPath = "./TenantHealthDashboard-$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "\nDashboard exported to $csvPath" -ForegroundColor Green
# ==================================================================
