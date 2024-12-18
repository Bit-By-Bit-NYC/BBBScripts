# Define the registry paths for both 32-bit and 64-bit systems
$paths = @(
    "HKLM:\Software\Microsoft\Cryptography\Wintrust\Config",
    "HKLM:\Software\Wow6432Node\Microsoft\Cryptography\Wintrust\Config"
)

# Loop through each path and create the registry key and value if not present
foreach ($path in $paths) {
    # Create the registry key if it doesn't exist
    if (-not (Test-Path -Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }

    # Set the EnableCertPaddingCheck value to 1
    Set-ItemProperty -Path $path -Name "EnableCertPaddingCheck" -Value 1 -PropertyType DWORD -Force
}

# Output success message
Write-Output "EnableCertPaddingCheck has been added and enabled in both 32-bit and 64-bit registry paths successfully."
