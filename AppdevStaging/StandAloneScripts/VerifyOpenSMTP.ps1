# List of IP addresses to test
$ips = @(
    "74.119.228.103", "74.119.228.112", "74.119.228.113", "74.119.228.119",
    "74.119.228.120", "74.119.228.123", "74.119.228.15",  "74.119.228.16",
    "74.119.228.19",  "74.119.228.83",  "74.119.228.86",  "74.119.229.135",
    "74.119.229.18",  "74.119.229.236", "74.119.229.237", "74.119.229.238",
    "74.119.230.107", "74.119.230.161", "74.119.230.163", "74.119.230.169",
    "74.119.230.178", "74.119.230.239", "74.119.230.78",  "74.119.230.79",
    "74.119.230.98"
)

# Port to test (SMTP)
$port = 25

# Results storage
$results = @()

foreach ($ip in $ips) {
    Write-Host "Testing $ip on port $port..." -ForegroundColor Cyan
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcp.BeginConnect($ip, $port, $null, $null)
        $wait = $asyncResult.AsyncWaitHandle.WaitOne(3000, $false) # 3 sec timeout
        if ($wait -and $tcp.Connected) {
            $stream = $tcp.GetStream()
            $reader = New-Object System.IO.StreamReader($stream)
            Start-Sleep -Milliseconds 500
            $banner = $reader.ReadLine()
            $tcp.Close()
            $status = "Open"
            Write-Host "  -> SMTP Open. Banner: $banner" -ForegroundColor Green
        } else {
            $status = "Closed"
            $banner = ""
            Write-Host "  -> SMTP Closed or Timed Out." -ForegroundColor Yellow
        }
    } catch {
        $status = "Error"
        $banner = $_.Exception.Message
        Write-Host "  -> Error: $banner" -ForegroundColor Red
    }
    $stopwatch.Stop()

    $results += [PSCustomObject]@{
        IP         = $ip
        Port       = $port
        Status     = $status
        TimeMS     = $stopwatch.ElapsedMilliseconds
        Banner     = $banner
    }
}

# Display results
$results | Format-Table -AutoSize

# Summary
$open   = ($results | Where-Object { $_.Status -eq "Open" }).Count
$closed = ($results | Where-Object { $_.Status -eq "Closed" }).Count
$errors  = ($results | Where-Object { $_.Status -eq "Error" }).Count

Write-Host "`nSummary:"
Write-Host "-----------"
Write-Host "Total IPs Tested: $($results.Count)"
Write-Host "Open:             $open"
Write-Host "Closed:           $closed"
Write-Host "Errors:           $errors"