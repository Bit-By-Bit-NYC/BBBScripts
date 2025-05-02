using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module Az.Accounts

try {
    Write-Host "🔐 Starting token acquisition..."
    Add-Type -AssemblyName "System.Data"

    try {
        $accessToken = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token
        Write-Host "✅ Access token acquired via Get-AzAccessToken"
    }
    catch {
        Write-Host "❌ Failed to acquire token via Get-AzAccessToken: $($_.Exception.Message)"
        throw
    }

    $connectionString = "Server=tcp:bbbai.database.windows.net,1433;Initial Catalog=bbbazuredb;"
    Write-Host "🔌 Opening SQL connection to bbbazuredb..."
    Write-Host "🔑 Using token of length $($accessToken.Length)"
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = $connectionString
    $conn.AccessToken = $accessToken
    $conn.Open()
    Write-Host "✅ SQL connection opened"

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT TenantName, TenantId FROM Tenants"
    Write-Host "📥 Executing query: $($cmd.CommandText)"

    $reader = $cmd.ExecuteReader()
    $results = @()
    while ($reader.Read()) {
        $tenantName = $reader["TenantName"]
        $tenantId = $reader["TenantId"]
        Write-Host "➡️ Found: $tenantName [$tenantId]"
        $results += @{
            TenantName = $tenantName
            TenantId   = $tenantId
        }
    }
    $conn.Close()
    Write-Host "✅ SQL connection closed"

    $body = $results | ConvertTo-Json -Depth 3
    Write-Host "✅ Returning results"

    return @{
        StatusCode = [HttpStatusCode]::OK
        Headers = @{ "Content-Type" = "application/json" }
        Body = $body
    }
}
catch {
    Write-Host "❌ ERROR: $($_.Exception.Message)"
    Write-Host "🧵 Connection string used: $connectionString"
    Write-Host "❌ STACK TRACE: $($_.Exception.StackTrace)"
    return @{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers = @{ "Content-Type" = "application/json" }
        Body = "Internal Server Error"
    }
}
