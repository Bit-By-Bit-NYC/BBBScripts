# List of Microsoft domains to add to Trusted Sites (Zone 2)
$domains = @(
    "login.microsoftonline.com",
    "aadcdn.msftauth.net",
    "aadcdn.msauth.net",
    "account.activedirectory.windowsazure.com",
    "accounts.accesscontrol.windows.net",
    "graph.windows.net",
    "graph.microsoft.com",
    "portal.office.com",
    "secure.aadcdn.microsoftonline-p.com",
    "login.live.com",
    "microsoftonline.com",
    "microsoft.com",
    "windows.net"
)

$registryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"

foreach ($domain in $domains) {
    # Split domains to support subkeys (e.g., microsoftonline.com -> microsoftonline.com)
    $parts = $domain -split '\.'

    if ($parts.Length -ge 2) {
        $baseDomain = "$($parts[$parts.Length - 2]).$($parts[$parts.Length - 1])"
        $subdomain = ($parts[0..($parts.Length - 3)] -join ".")
    } else {
        $baseDomain = $domain
        $subdomain = ""
    }

    $domainKey = Join-Path $registryPath $baseDomain
    if (!(Test-Path $domainKey)) {
        New-Item -Path $domainKey -Force | Out-Null
    }

    if ($subdomain) {
        $subKey = Join-Path $domainKey $subdomain
        if (!(Test-Path $subKey)) {
            New-Item -Path $subKey -Force | Out-Null
        }
        New-ItemProperty -Path $subKey -Name "*" -Value 2 -PropertyType DWord -Force | Out-Null
    } else {
        New-ItemProperty -Path $domainKey -Name "*" -Value 2 -PropertyType DWord -Force | Out-Null
    }

    Write-Output "Added $domain to Trusted Sites"
}
