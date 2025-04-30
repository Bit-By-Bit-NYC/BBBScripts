try {
    $connString = "Server=tcp:bbbai.database.windows.net,1433;Initial Catalog=bbbazuredb;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

    Write-Host "Connecting to SQL using Managed Identity..."
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = $connString
    $conn.AccessToken = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token
    $conn.Open()

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT TenantName, TenantId FROM Tenants"

    $reader = $cmd.ExecuteReader()
    $results = @()
    while ($reader.Read()) {
        $results += @{
            TenantName = $reader["TenantName"]
            TenantId   = $reader["TenantId"]
        }
    }
    $conn.Close()

    $body = $results | ConvertTo-Json -Depth 3
    return @{ StatusCode = 200; Body = $body }
}
catch {
    Write-Host "❌ ERROR: $($_.Exception.Message)"
    return @{ StatusCode = 500; Body = "Function failed: $($_.Exception.Message)" }
}