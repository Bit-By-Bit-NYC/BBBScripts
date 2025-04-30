# === CONFIGURATION ===
$functionUrl = "https://func-bbb-tenantapi.azurewebsites.net/api/GetTenants"
$functionKey = "CXnijHY0KarQoLMtvOYdy-pXLRJ0GoumW9TY1RIhpxCNAzFu2eP6Pw=="

# === BUILD FULL URL with function key ===
$uri = "$functionUrl?code=$functionKey"

# === CALL FUNCTION ===
try {
    Write-Host "`nCalling Azure Function to retrieve tenants..." -ForegroundColor Cyan
    $response = Invoke-RestMethod -Uri $uri -Method Get

    Write-Host "`nTenants retrieved from API:" -ForegroundColor Green
    $response | Format-Table TenantName, TenantId -AutoSize
}
catch {
    Write-Error "❌ Failed to call Azure Function: $_"
}
