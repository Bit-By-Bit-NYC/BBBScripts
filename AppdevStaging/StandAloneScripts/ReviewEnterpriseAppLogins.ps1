# Connect to Microsoft Graph
Connect-MgGraph -Scopes "AuditLog.Read.All", "Application.Read.All"

# Get all service principals (enterprise applications)
$apps = Get-MgServicePrincipal -All

# Create cutoff date (30 days ago)
$cutoff = (Get-Date).AddDays(-30)

# Prepare results
$results = @()

# Loop through each app
foreach ($app in $apps) {
    try {
        # Optional visual progress
        Write-Host "🔍 Checking: $($app.DisplayName)" -ForegroundColor Cyan

        # Query sign-in logs by AppId
        $signIns = Get-MgAuditLogSignIn -Filter "appId eq '$($app.AppId)'" -Top 1 -Sort "createdDateTime desc"

        if ($signIns) {
            $lastSignIn = [DateTime]$signIns[0].createdDateTime

            # Color-coded output
            if ($lastSignIn -gt $cutoff) {
                Write-Host "✅ $($app.DisplayName) - Last Sign-In: $lastSignIn" -ForegroundColor Green
            } else {
                Write-Host "⚠️ $($app.DisplayName) - Last Sign-In: $lastSignIn" -ForegroundColor DarkGray
            }
        } else {
            $lastSignIn = $null
            Write-Host "⛔ $($app.DisplayName) - No Sign-In Found" -ForegroundColor DarkGray
        }

        # Add to result set
        $results += [PSCustomObject]@{
            DisplayName = $app.DisplayName
            AppId       = $app.AppId
            ObjectId    = $app.Id
            LastSignIn  = $lastSignIn
        }
    }
    catch {
        Write-Warning "Error checking $($app.DisplayName): $_"
    }
}

# Export results to CSV
$results | Export-Csv -Path "./EnterpriseAppsLastSignIn.csv" -NoTypeInformation