# Define the URLs to add
$urls = @(
    "https://*.egnyte.com",
    "file://egnytedrive"
)

# Define the registry path for Trusted Sites (for all users)
$regPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"

# Add each URL to the registry
foreach ($url in $urls) {
    # Extract the domain, handling wildcards and "file:" URLs
    $domain = switch -regex ($url) {
        "^https?://(?:www\.)?\*?\.?([^/]+)" { $Matches[1] }
        "^file://(.+)" { $Matches[1] }
        default { $url }
    }

    # Create the registry key for the domain (without protocol)
    New-Item -Path "$regPath\$domain" -Force | Out-Null

    # Set the registry value to 2 (Trusted Sites zone)
    New-ItemProperty -Path "$regPath\$domain" -Name "*" -Value 2 -PropertyType DWord -Force
}