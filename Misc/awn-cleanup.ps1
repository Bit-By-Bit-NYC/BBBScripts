# Step 1: Attempt graceful uninstall for all registered 'Arctic Wolf Agent' products
Write-Host "Step 1: Attempting graceful uninstall of any existing 'Arctic Wolf Agent' products..."
$Apps = Get-ItemProperty HKLM:\SOFTWARE\*\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Arctic Wolf Agent*" }

if ($Apps) { 
    foreach ($App in $Apps) {
        if ($App.UninstallString) {
            $logFile = "C:\temp\AW_Uninstall_$($App.DisplayName -replace '[^a-zA-Z0-9]','_')_$(Get-Date -f yyyyMMdd-HHmmss).log"
            # Build the uninstall arguments, force /x (uninstall) and add logging/quiet flags
            $uninstallArgs = ($App.UninstallString -replace '(?i)/i', '/x').Split(' ', 2)[1] + " /quiet /norestart /L*v `"$logFile`""
            Write-Host "Uninstalling $($App.DisplayName)... Log: $logFile"
            Start-Process msiexec.exe -ArgumentList $uninstallArgs -Wait
            Write-Host "'$($App.DisplayName)' uninstall complete."
        } else {
            Write-Host "Found $($App.DisplayName) but it has no UninstallString. Skipping."
        }
    }
} else { 
    Write-Host "No registered products matching 'Arctic Wolf Agent' found. Proceeding to manual cleanup."
}

# Step 2: Force-delete the installation directory
Write-Host "Step 2: Force-deleting installation directory..."
$InstallDir = "C:\Program Files (x86)\Arctic Wolf Networks\Agent\"
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $InstallDir."
} else {
    Write-Host "Directory $InstallDir not found, skipping."
}

# Step 3: Nuke all known conflicting registry keys (Installer DB, UpgradeCodes, and Uninstall entries)
Write-Host "Step 3: Force-deleting all known conflicting registry keys..."
@("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{CE73C156-7AE3-46B8-9231-2CC9BBB6A1EF}", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{CE73C156-7AE3-46B8-9231-2CC9BBB6A1EF}", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{574A536C-7EF4-40D9-8887-85B34ADFD716}", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{574A536C-7EF4-40D9-8887-85B34ADFD716}", "HKLM:\SOFTWARE\Classes\Installer\Products\651C37EC3EA78B642913C29CBB6B1AFE", "HKLM:\SOFTWARE\Classes\Installer\Products\C635A4754FE79D048788583B4ADFD761", "HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\60DED544E44DAF54FB34732FBDCCBA71") | ForEach-Object { 
    if (Test-Path $_) {
        Write-Host "Removing: $_"
        Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue 
    }
}

Write-Host "✅ Full cleanup complete. System is ready for re-installation."# Step 1: Attempt graceful uninstall for all registered 'Arctic Wolf Agent' products
Write-Host "Step 1: Attempting graceful uninstall of any existing 'Arctic Wolf Agent' products..."
$Apps = Get-ItemProperty HKLM:\SOFTWARE\*\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Arctic Wolf Agent*" }

if ($Apps) { 
    foreach ($App in $Apps) {
        if ($App.UninstallString) {
            $logFile = "C:\temp\AW_Uninstall_$($App.DisplayName -replace '[^a-zA-Z0-9]','_')_$(Get-Date -f yyyyMMdd-HHmmss).log"
            # Build the uninstall arguments, force /x (uninstall) and add logging/quiet flags
            $uninstallArgs = ($App.UninstallString -replace '(?i)/i', '/x').Split(' ', 2)[1] + " /quiet /norestart /L*v `"$logFile`""
            Write-Host "Uninstalling $($App.DisplayName)... Log: $logFile"
            Start-Process msiexec.exe -ArgumentList $uninstallArgs -Wait
            Write-Host "'$($App.DisplayName)' uninstall complete."
        } else {
            Write-Host "Found $($App.DisplayName) but it has no UninstallString. Skipping."
        }
    }
} else { 
    Write-Host "No registered products matching 'Arctic Wolf Agent' found. Proceeding to manual cleanup."
}

# Step 2: Force-delete the installation directory
Write-Host "Step 2: Force-deleting installation directory..."
$InstallDir = "C:\Program Files (x86)\Arctic Wolf Networks\Agent\"
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $InstallDir."
} else {
    Write-Host "Directory $InstallDir not found, skipping."
}

# Step 3: Nuke all known conflicting registry keys (Installer DB, UpgradeCodes, and Uninstall entries)
Write-Host "Step 3: Force-deleting all known conflicting registry keys..."
@("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{CE73C156-7AE3-46B8-9231-2CC9BBB6A1EF}", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{CE73C156-7AE3-46B8-9231-2CC9BBB6A1EF}", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{574A536C-7EF4-40D9-8887-85B34ADFD716}", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{574A536C-7EF4-40D9-8887-85B34ADFD716}", "HKLM:\SOFTWARE\Classes\Installer\Products\651C37EC3EA78B642913C29CBB6B1AFE", "HKLM:\SOFTWARE\Classes\Installer\Products\C635A4754FE79D048788583B4ADFD761", "HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\60DED544E44DAF54FB34732FBDCCBA71") | ForEach-Object { 
    if (Test-Path $_) {
        Write-Host "Removing: $_"
        Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue 
    }
}

Write-Host "✅ Full cleanup complete. System is ready for re-installation."