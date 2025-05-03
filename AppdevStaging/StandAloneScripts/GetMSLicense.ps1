# ==================================================================
# Script: Export Microsoft 365 Licensing Info by Tenant
# Method: Service Principal Authentication (Azure CLI Token Injection)
# Platform: Cross-platform (Mac, Windows, Linux)
# Author: ChatGPT + Jim collaboration
# Date: 2025-04-28
# ==================================================================

# --- CONFIGURATION: Hardcoded Tenants ---
$tenants = @{
    "1" = @{ Name = "Bit By Bit Computer Consultants"; Id = "27f318ae-79fe-4219-aa14-689300d7365c" }
    "2" = @{ Name = "scemsny.com"; Id = "6e35e8df-159a-4d3a-8d09-687ad995e311" }
    "3" = @{ Name = "Daniel H Cook and Associates"; Id = "6a56dc62-92c4-461a-b932-bb35887b2c80" }
}

# --- DISPLAY TENANT OPTIONS ---
Write-Host "`nAvailable Tenants:"
foreach ($key in $tenants.Keys | Sort-Object) {
    $t = $tenants[$key]
    Write-Host "$key. $($t.Name) [$($t.Id)]"
}

# --- USER SELECTS TENANT ---
[int]$selection = Read-Host "`nSelect a tenant number"
if (-not $tenants.ContainsKey($selection.ToString())) {
    Write-Error "Invalid selection. Exiting..."
    exit
}

$selectedTenant = $tenants[$selection.ToString()]
$TenantId = $selectedTenant.Id
$TenantName = $selectedTenant.Name

Write-Host "`nUsing tenant: $TenantName ($TenantId)" -ForegroundColor Green

# --- SERVICE PRINCIPAL INFO ---
$ClientId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1"  # Your Service Principal App ID
$ClientSecret = Read-Host "Enter client secret for the service principal"

# --- Authenticate via Azure CLI and Retrieve Access Token ---
Write-Host "`nAuthenticating with Azure CLI (Service Principal)..."

az logout | Out-Null

$azLogin = az login --service-principal -u $ClientId -p $ClientSecret --tenant $TenantId --allow-no-subscriptions | ConvertFrom-Json

$accessToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv

if (-not $accessToken) {
    Write-Error "Failed to retrieve access token. Exiting..."
    exit
}

# --- Secure the Token ---
$secureToken = ConvertTo-SecureString -String $accessToken -AsPlainText -Force

# --- Connect to Microsoft Graph ---
Connect-MgGraph -AccessToken $secureToken

# Confirm Connection
$whoami = Get-MgContext
Write-Host "`nConnected as AppId: $($whoami.ClientId) against Tenant: $($whoami.TenantId)" -ForegroundColor Green

# ==================================================================
# --- Pull User Information ---
Write-Host "`nPulling users from Entra ID (Azure AD)...`n"

#$allUsers = Get-MgUser -All -Property DisplayName, UserPrincipalName, AssignedLicenses


$allUsers = Get-MgUser -All -Property DisplayName, UserPrincipalName, AssignedLicenses, SignInActivity



# --- SKU Mapping Table (Expand as Needed) ---
$skuMap = @{
    # Microsoft 365 SKUs
    "3b555118-da6a-4418-894f-7df1e2096870" = "Microsoft 365 Business Standard"
    "c42b9cae-ea4f-4ab7-9717-81576235ccac" = "Microsoft 365 E3"
    "06ebc4ee-1bb5-47dd-8120-11324bc54e06" = "Microsoft 365 E5"
    "17b1c7e9-84c9-4f53-95e0-4786a9d46d84" = "Microsoft 365 Business Premium"
    "e2c4a4de-2b45-4b36-b6b2-10d4dc047b36" = "Microsoft 365 F1"
    "f30db892-07e9-47e9-837c-80727f46fd3d" = "Microsoft 365 F3"

    # Office 365 SKUs
    "6fd2c87f-b296-42f0-b197-1e91e994b900" = "Office 365 E3"
    "c7df2760-2c81-4ef7-b578-5b5392b571df" = "Office 365 E1"
    "e5e2ac9b-17a3-4697-8b2d-ebf37c6d8cf5" = "Office 365 E5"
    "4b9405b0-7788-4568-add1-99614e613b69" = "Office 365 Business Premium (Old)"
    "f245ecc8-75af-4f8e-b61f-27d8114de5f3" = "Microsoft Teams Exploratory"

    # Azure AD / Entra ID SKUs
    "41781fb2-bc02-4b7c-bd55-b576c07bb09d" = "Azure Active Directory Premium P1 (Entra ID P1)"
    "e1a6a52e-61a2-4135-9c4b-2dea7fc2a5a2" = "Azure Active Directory Premium P2 (Entra ID P2)"
    "b05e124f-c7cc-45a0-a6aa-8cf78c946968" = "Azure AD Free"
    "50e68fd9-AD66-497f-A651-7EFC003A2E3D" = "Microsoft Entra ID Governance"

    # EMS + Security
    "88b5b5f0-2c43-4f0a-b9b3-2cc9a4e5fe02" = "Enterprise Mobility + Security E3"
    "c2d2b212-1b5c-423b-9f44-3944f4c4f408" = "Enterprise Mobility + Security E5"
    "94c8dff2-128a-49f9-8b92-fb5e0a7633e5" = "Microsoft Defender for Endpoint P1"
    "871d91ec-ec1a-452b-9b5c-2d4bbd8d6c61" = "Microsoft Defender for Endpoint P2"

    # Power Platform
    "e0dfc8b9-9531-4ec8-94b4-9fec23b05fc8" = "Microsoft Power Apps Plan 2"
    "d4ebce55-015a-49b5-a083-c84d1797ae8c" = "Microsoft Power BI Pro"
    "c2f3c9c1-038e-4bf5-8c5d-44b8b7b7f9fe" = "Microsoft Power BI Free"

    # Dynamics 365 SKUs (optional if you need)
    "e95bec33-7c88-41ac-9b74-03d2e6045e9f" = "Dynamics 365 Customer Service Enterprise"
    "3fa5cb26-89b1-4393-9374-c67e63f8ee02" = "Dynamics 365 Sales Enterprise"

    # Additional SKUs from DHC
    "05e9a617-0261-4cee-bb44-138d3ef5d965" = "Microsoft 365 F3"
    "e43b5b99-8dfb-405f-9987-dc307f3efb6c" = "Microsoft Teams Exploratory"
    "96d2951e-cb42-4481-9d6d-cad3baaf077b" = "Microsoft Defender for Endpoint P1"
    "639dec6b-bb19-468b-871c-c5c441c2000e" = "Microsoft Defender for Endpoint P2"
    "4cde982a-ede4-4409-9ae6-b00345398615" = "Microsoft Power BI (Unverified Plan)"
}

# --- Build Export List ---
$exportList = @()

foreach ($user in $allUsers) {
    # Determine if PARIO user
    $isPario = $false
    if ($user.UserPrincipalName -like "*PARIO*") {
        $isPario = $true
    }

    # Build License Names
    $licenseNames = @()
    if ($user.AssignedLicenses.Count -gt 0) {
        foreach ($license in $user.AssignedLicenses) {
            if ($skuMap.ContainsKey($license.SkuId.ToString())) {
                $licenseNames += $skuMap[$license.SkuId.ToString()]
            }
            else {
                $licenseNames += $license.SkuId  # fallback to raw SKU ID
            }
        }
    } else {
        $licenseNames += "None"
    }

    # Add user record
    $exportList += [PSCustomObject]@{
        DisplayName       = $user.DisplayName
        UserPrincipalName = $user.UserPrincipalName
        IsPARIO           = $isPario
        CurrentLicenses   = ($licenseNames -join "; ")
        LastSignInDate    = if ($user.SignInActivity.LastSignInDateTime) { [datetime]$user.SignInActivity.LastSignInDateTime | Get-Date -Format "yyyy-MM-dd HH:mm:ss" } else { "" }
    }
}

# --- Display in Table ---
Write-Host "`nUser List:"
$exportList | Format-Table -AutoSize

# --- Export to CSV ---
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmm")
$csvPath = "./User_Licensing_Plan-$timestamp.csv"

$exportList | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "`nUser Licensing Plan exported to $csvPath" -ForegroundColor Green

# ==================================================================
Write-Host "`n✅ Script complete!" -ForegroundColor Green