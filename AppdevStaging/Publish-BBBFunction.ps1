# Publish.ps1 - Helper to save required modules and deploy Azure Function

# Navigate to the root of your Azure Function project
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Ensure Modules directory exists
if (-not (Test-Path "./Modules")) {
    Write-Host "📁 Creating Modules directory..."
    New-Item -Path "./Modules" -ItemType Directory | Out-Null
}

# Save Az.Accounts module
Write-Host "💾 Saving Az.Accounts module to ./Modules..."
Save-Module -Name Az.Accounts -RequiredVersion 2.13.2 -Path "./Modules" -Force

# Publish to Azure
Write-Host "🚀 Publishing Azure Function App..."
func azure functionapp publish func-bbb-tenantapi --powershell
