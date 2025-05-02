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
    "2" = @{ Name = "SeniorCare"; Id = "b550b5ea-7463-4810-b74c-43617d8335d1" }
    # Add rest of your tenants here...
}

# --- USER PROMPT FOR CLIENT SECRET ---
$ClientSecret = Read-Host "Enter client secret for the Service Principal" -AsSecureString
$PlainClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))

# --- RESULTS HOLDER ---
$results = @()

# --- MAIN LOOP ---
foreach ($key in ($tenants.Keys | Sort-Object)) {
    $tenant = $tenants[$key]
    Write-Host "\nChecking Tenant: $($tenant.Name) ($($tenant.Id))..." -ForegroundColor Cyan

    # Set environment variables for Service Principal authentication
    $env:AZURE_CLIENT_ID = $ClientId
    $env:AZURE_TENANT_ID = $tenant.Id
    $env:AZURE_CLIENT_SECRET = $PlainClientSecret

    # Connect to Microsoft Graph
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Connect-MgGraph -Identity -Scopes "https://graph.microsoft.com/.default" -ErrorAction Stop
        $connected = $true
    }
    catch {
        Write-Host "Failed to connect to tenant." -ForegroundColor Red
        $connected = $false
    }

    # Initialize checks
    $licenseStatus = "N/A"
    $rebootStatus = "N/A"
    $patchStatus = "N/A"
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

        # Check if Service Principals exist
        foreach ($app in $appNames) {
            try {
                $sp = Get-MgServicePrincipal -Filter "displayName eq '$app'" -Top 1 -ErrorAction Stop
                if ($sp) {
                    if ($app -eq "BBB MS Licensing") { $licensingApp = "🟢" }
                    elseif ($app -eq "BBB MS Reboot") { $rebootApp = "🟢" }
                    elseif ($app -eq "BBB MS Patch") { $patchApp = "🟢" }
                }
            }
            catch {
                if ($app -eq "BBB MS Licensing") { $licensingApp = "🔴" }
                elseif ($app -eq "BBB MS Reboot") { $rebootApp = "🔴" }
                elseif ($app -eq "BBB MS Patch") { $patchApp = "🔴" }
            }
        }

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
