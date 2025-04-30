using namespace System.Net


param($Request, $TriggerMetadata)


try {
    Import-Module Az.Accounts -ErrorAction Stop
    Write-Host "✅ Az.Accounts module loaded successfully."
}
catch {
    Write-Host "❌ ERROR: Failed to import Az.Accounts: $($_.Exception.Message)"
    return @{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers = @{ "Content-Type" = "application/json" }
        Body = "Internal Server Error: Failed to load Az.Accounts"
    }
}


try {
    Write-Host "🔐 Starting token acquisition..."
    $token = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token
    Write-Host "✅ Access token acquired: $($token.Substring(0,20))..."

    $connectionString = "Server=tcp:bbbai.database.windows.net,1433;Initial Catalog=bbbazuredb;"
    Write-Host "🔌 Opening SQL connection to bbbazuredb..."
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = $connectionString
    $conn.AccessToken = $token
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
    Write-Host "❌ STACK TRACE: $($_.Exception.StackTrace)"
    return @{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers = @{ "Content-Type" = "application/json" }
        Body = "Internal Server Error"
    }
}
