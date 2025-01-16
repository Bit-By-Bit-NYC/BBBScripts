# Find Outlook search key
$outlookSearchKey = 'Software\Microsoft\Office\*\Outlook\Profiles'

# Get all user SIDs under HKU
$userSIDs = Get-ChildItem Registry::HKU | Where-Object { $_.PSIsContainer } | Select-Object -ExpandProperty Name

# Iterate over each user
foreach ($sid in $userSIDs) {
    $userKey = "HKU:\$sid\$outlookSearchKey"

    if (Test-Path $userKey) {
        Write-Host "Searching profile(s) for user:" $sid

        # Find PST store paths for this user
        Get-ChildItem -Path $userKey -Recurse |
            Where-Object { $_.Name -like '*.pst' } |
            ForEach-Object {
                try {
                    $pstPath = [System.Text.Encoding]::Unicode.GetString($_.GetValue(''))
                      Write-Host "  Found PST:" $pstPath
                } catch {
                    Write-Warning "  Could not decode PST path from: $($_.PSPath)"
                }
            }
    }
}
