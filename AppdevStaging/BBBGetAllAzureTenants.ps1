# ==================================================================
# Script: Generate Full Tenant List for Dashboard
# Method: Service Principal Login + Graph API Call
# Author: ChatGPT + Jim Collaboration
# Date: 2025-04-28
# ==================================================================

# --- CONFIGURATION ---

# Service Principal Info
$ClientId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1"  # Your App Client ID

# --- USER PROMPT FOR CLIENT SECRET ---
$ClientSecret = Read-Host "Enter client secret for the Service Principal" -AsSecureString
$PlainClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))

# --- AUTHENTICATE ---
Write-Host "\nConnecting to Microsoft Graph..." -ForegroundColor Cyan
$env:AZURE_CLIENT_ID = $ClientId
$env:AZURE_CLIENT_SECRET = $PlainClientSecret
$env:AZURE_TENANT_ID = "27f318ae-79fe-4219-aa14-689300d7365c"

try {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    Connect-MgGraph -Identity -Scopes "https://graph.microsoft.com/.default" -ErrorAction Stop
    Write-Host "Connected successfully." -ForegroundColor Green
}
catch {
    Write-Host "Failed to connect." -ForegroundColor Red
    exit
}

# --- QUERY ORGANIZATIONS ---
Write-Host "\nRetrieving tenants (organizations)..." -ForegroundColor Cyan

$orgs = Get-MgOrganization -All

# --- BUILD TENANTS BLOCK ---
Write-Host "\nBuilding tenant block..." -ForegroundColor Cyan

$psBlock = "$tenants = @{\n"
$counter = 1

# Insert Bit By Bit and SeniorCare manually first
$manualEntries = @(
    @{ Name = "Bit By Bit Computer Consultants"; Id = "27f318ae-79fe-4219-aa14-689300d7365c" },
    @{ Name = "SeniorCare"; Id = "b550b5ea-7463-4810-b74c-43617d8335d1" }
)

foreach ($entry in $manualEntries) {
    $psBlock += "    `"$counter`" = @{ Name = `"$($entry.Name)`"; Id = `"$($entry.Id)`" }`n"
    $counter++
}

# Then add discovered tenants
foreach ($org in ($orgs | Sort-Object DisplayName)) {
    $psBlock += "    `"$counter`" = @{ Name = `"$($org.DisplayName)`"; Id = `"$($org.Id)`" }`n"
    $counter++
}

$psBlock += "}"

# --- OUTPUT ---
Write-Host "\n\nCopy and paste this into your dashboard script:`n" -ForegroundColor Green
Write-Output $psBlock

# Optional: Save to a file
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmm")
$path = "./TenantList-$timestamp.ps1"
$psBlock | Out-File -Encoding UTF8 -FilePath $path

Write-Host "\nTenant list also saved to: $path" -ForegroundColor Green
# ==================================================================
