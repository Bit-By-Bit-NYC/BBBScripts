# Find Outlook search key (registry)
$outlookSearchKey = 'Software\Microsoft\Office\*\Outlook\Profiles'

# PST file extension
$pstExtension = '*.pst'

# Output file
$outputFile = 'C:\kworking\pst_files.csv'

# Get all user SIDs under HKU
$userSIDs = Get-ChildItem Registry::HKU | Where-Object { $_.PSIsContainer } | Select-Object -ExpandProperty Name

# Array to store PST file paths and count variable
$pstFiles = @()
$pstCount = 0

# Iterate over each user
foreach ($sid in $userSIDs) {
    $userKey = "HKU:\$sid\$outlookSearchKey"

    if (Test-Path $userKey) {
        # Search registry for PST files
        $registryPstFiles = Get-ChildItem -Path $userKey -Recurse |
            Where-Object { $_.Name.ToLower() -like $pstExtension } |
            ForEach-Object {
                try {
                    $pstPath = [System.Text.Encoding]::Unicode.GetString($_.GetValue(''))
                    if ((Split-Path $pstPath -Leaf).ToLower() -like $pstExtension) {
                        $pstFiles += New-Object PSObject -Property @{
                            'User SID' = $sid
                            'Path' = $pstPath
                            'Source' = 'Registry'
                        }
                        $pstCount++  # Increment the count
                    }
                } catch {
                    Write-Warning "  Could not decode PST path from: $($_.PSPath)"
                }
            }
    }
}

# Search common file system locations (including Documents and Desktop)
$searchPatterns = @(
    (Join-Path $env:USERPROFILE 'Documents\Outlook Files'),
    (Join-Path $env:USERPROFILE 'AppData\Local\Microsoft\Outlook'),
    (Join-Path $env:USERPROFILE 'Documents'), # User's Documents folder
    (Join-Path $env:USERPROFILE 'Desktop')    # User's Desktop folder
)

foreach ($searchPattern in $searchPatterns) {
    if (Test-Path $searchPattern) {
        $fileSystemPstFiles = Get-ChildItem -Path $searchPattern -Filter $pstExtension -Recurse 
        $pstFiles += $fileSystemPstFiles | ForEach-Object {
            New-Object PSObject -Property @{
                'User SID' = $null
                'Path' = $_.FullName
                'Source' = 'File System'
            }
        }
        $pstCount += $fileSystemPstFiles.Count # Increment the count
    }
}

# Export to CSV
$pstFiles | Export-Csv -Path $outputFile -NoTypeInformation

# Output the total count
Return $pstCount
