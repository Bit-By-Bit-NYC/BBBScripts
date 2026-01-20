<#
.SYNOPSIS
    Generate a report on Azure File Shares including backup and sync status

.DESCRIPTION
    This script scans all Azure File Shares across subscriptions and reports:
    - File Share details (name, storage account, resource group)
    - Backup status (whether protected by Azure Backup)
    - Sync status (whether part of Azure File Sync)
    Output is displayed on screen and exported to CSV and Excel

.PARAMETER SubscriptionId
    Optional. Specific subscription ID to scan. If not provided, scans all accessible subscriptions.

.PARAMETER OutputPath
    Optional. Path for output files. Default is current directory.

.EXAMPLE
    .\Get-AzureFileShareReport.ps1
    
.EXAMPLE
    .\Get-AzureFileShareReport.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -OutputPath "C:\Reports"
#>

param(
    [string]$SubscriptionId,
    [string]$OutputPath = "."
)

# Function to check if module is installed
function Test-ModuleInstalled {
    param([string]$ModuleName)
    return (Get-Module -ListAvailable -Name $ModuleName)
}

# Check and install required modules
Write-Host "Checking required PowerShell modules..." -ForegroundColor Cyan

$requiredModules = @('Az.Accounts', 'Az.Storage', 'Az.RecoveryServices', 'Az.StorageSync', 'ImportExcel')

foreach ($module in $requiredModules) {
    if (-not (Test-ModuleInstalled -ModuleName $module)) {
        Write-Host "Module '$module' not found. Installing..." -ForegroundColor Yellow
        try {
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
            Write-Host "Module '$module' installed successfully." -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to install '$module'. Excel export may not work if ImportExcel is missing."
        }
    }
}

# Import modules
Import-Module Az.Accounts -ErrorAction SilentlyContinue
Import-Module Az.Storage -ErrorAction SilentlyContinue
Import-Module Az.RecoveryServices -ErrorAction SilentlyContinue
Import-Module Az.StorageSync -ErrorAction SilentlyContinue
Import-Module ImportExcel -ErrorAction SilentlyContinue

# Connect to Azure
Write-Host "`nConnecting to Azure..." -ForegroundColor Cyan
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount
    }
    Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Azure. Please run Connect-AzAccount manually."
    exit 1
}

# Get subscriptions to scan
if ($SubscriptionId) {
    $subscriptions = Get-AzSubscription -SubscriptionId $SubscriptionId
}
else {
    $subscriptions = Get-AzSubscription
}

Write-Host "`nScanning $($subscriptions.Count) subscription(s)..." -ForegroundColor Cyan

# Initialize report array
$report = @()

foreach ($subscription in $subscriptions) {
    Write-Host "`nProcessing Subscription: $($subscription.Name) ($($subscription.Id))" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $subscription.Id | Out-Null
    
    # Get all Recovery Services Vaults for backup checking
    Write-Host "  - Retrieving Recovery Services Vaults..." -ForegroundColor Gray
    $backupVaults = Get-AzRecoveryServicesVault
    Write-Host "    Found $($backupVaults.Count) Recovery Services Vault(s)" -ForegroundColor Gray
    
    # Build backup lookup table
    $backupLookup = @{}
    foreach ($vault in $backupVaults) {
        try {
            Write-Host "    Checking vault: $($vault.Name)" -ForegroundColor Gray
            Set-AzRecoveryServicesVaultContext -Vault $vault
            
            # Get containers first to check if there are any backups
            $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -ErrorAction SilentlyContinue
            
            if ($containers) {
                Write-Host "      Found $($containers.Count) backup container(s)" -ForegroundColor Gray
                foreach ($container in $containers) {
                    $backupItems = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureFiles -ErrorAction SilentlyContinue
                    
                    if ($backupItems) {
                        Write-Host "        Container: $($container.FriendlyName) has $($backupItems.Count) backup item(s)" -ForegroundColor Gray
                    }
                    
                    foreach ($item in $backupItems) {
                        # Extract storage account name from container
                        # Container name format: StorageContainer;Storage;ResourceGroupName;StorageAccountName
                        $containerParts = $container.Name -split ';'
                        $storageAccountName = if ($containerParts.Count -ge 4) { $containerParts[3] } else { $container.FriendlyName }
                        
                        # Get actual file share name from FriendlyName or SourceResourceId
                        $fileShareName = $null
                        
                        # Try to get from FriendlyName first (format: storageaccount;filesharename)
                        if ($item.FriendlyName -and $item.FriendlyName -match ';') {
                            $friendlyParts = $item.FriendlyName -split ';'
                            if ($friendlyParts.Count -ge 2) {
                                $fileShareName = $friendlyParts[1]
                            }
                        }
                        
                        # If not found, try to extract from SourceResourceId
                        if (-not $fileShareName -and $item.SourceResourceId) {
                            # Format: /subscriptions/.../storageAccounts/name/fileServices/default/fileshares/sharename
                            if ($item.SourceResourceId -match '/fileshares/([^/]+)$') {
                                $fileShareName = $matches[1]
                            }
                        }
                        
                        # Skip if we couldn't determine the file share name
                        if (-not $fileShareName) {
                            Write-Host "          Backup item: Could not determine file share name for $($item.Name)" -ForegroundColor Yellow
                            continue
                        }
                        
                        Write-Host "          Backup item: $storageAccountName/$fileShareName (Status: $($item.ProtectionStatus))" -ForegroundColor Gray
                        
                        # Create multiple keys to increase match chances
                        $key1 = "$storageAccountName/$fileShareName"
                        $key2 = "$($item.ContainerName)/$fileShareName"
                        $key3 = "$storageAccountName\$fileShareName"
                        
                        $backupData = @{
                            VaultName = $vault.Name
                            ProtectionStatus = $item.ProtectionStatus
                            LastBackupTime = $item.LastBackupTime
                            ProtectionState = $item.ProtectionState
                            StorageAccountName = $storageAccountName
                            FileShareName = $fileShareName
                        }
                        
                        $backupLookup[$key1] = $backupData
                        $backupLookup[$key2] = $backupData
                        $backupLookup[$key3] = $backupData
                    }
                }
            } else {
                Write-Host "      No backup containers found in this vault" -ForegroundColor Gray
            }
        }
        catch {
            Write-Warning "Could not retrieve backup items from vault: $($vault.Name) - $($_.Exception.Message)"
        }
    }
    
    $uniqueBackups = ($backupLookup.Values | Select-Object -Property StorageAccountName, FileShareName -Unique | Measure-Object).Count
    Write-Host "    Total unique backed up file share(s): $uniqueBackups" -ForegroundColor Green
    
    # Get all Storage Sync Services for sync checking
    Write-Host "  - Retrieving Storage Sync Services..." -ForegroundColor Gray
    $syncServices = Get-AzStorageSyncService -ErrorAction SilentlyContinue
    Write-Host "    Found $($syncServices.Count) Storage Sync Service(s)" -ForegroundColor Gray
    
    # Build sync lookup table
    $syncLookup = @{}
    foreach ($syncService in $syncServices) {
        try {
            $syncGroups = Get-AzStorageSyncGroup -ParentObject $syncService -ErrorAction SilentlyContinue
            
            foreach ($syncGroup in $syncGroups) {
                $cloudEndpoints = Get-AzStorageSyncCloudEndpoint -ParentObject $syncGroup -ErrorAction SilentlyContinue
                
                foreach ($endpoint in $cloudEndpoints) {
                    # Parse the storage account and file share from the endpoint
                    if ($endpoint.StorageAccountResourceId -and $endpoint.AzureFileShareName) {
                        $storageAccountName = ($endpoint.StorageAccountResourceId -split '/')[-1]
                        $key = "$storageAccountName/$($endpoint.AzureFileShareName)"
                        
                        $syncLookup[$key] = @{
                            SyncServiceName = $syncService.StorageSyncServiceName
                            SyncGroupName = $syncGroup.SyncGroupName
                            ProvisioningState = $endpoint.ProvisioningState
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "Could not retrieve sync groups from: $($syncService.StorageSyncServiceName)"
        }
    }
    
    # Get all storage accounts
    Write-Host "  - Retrieving Storage Accounts..." -ForegroundColor Gray
    $storageAccounts = Get-AzStorageAccount
    
    foreach ($sa in $storageAccounts) {
        Write-Host "    - Checking storage account: $($sa.StorageAccountName)" -ForegroundColor Gray
        
        try {
            # Get file shares - using Get to avoid duplicates from snapshots
            $shares = Get-AzStorageShare -Context $sa.Context -ErrorAction SilentlyContinue | Where-Object { $_.IsSnapshot -eq $false }
            
            if ($shares) {
                foreach ($share in $shares) {
                    # Check backup status
                    $backupKey = "$($sa.StorageAccountName)/$($share.Name)"
                    $backupInfo = $backupLookup[$backupKey]
                    
                    # Check sync status
                    $syncKey = "$($sa.StorageAccountName)/$($share.Name)"
                    $syncInfo = $syncLookup[$syncKey]
                    
                    # Get share properties and usage
                    $shareQuota = if ($share.Quota) { $share.Quota } elseif ($share.Properties.Quota) { $share.Properties.Quota } else { 0 }
                    
                    # Get actual usage by getting share stats
                    $shareUsageGB = 0
                    try {
                        $shareStats = $share.ShareClient.GetStatistics()
                        if ($shareStats -and $shareStats.Value) {
                            $shareUsageGB = [math]::Round($shareStats.Value.ShareUsageInBytes / 1GB, 2)
                        }
                    }
                    catch {
                        # If stats fail, try alternative method
                        try {
                            $shareUsageBytes = $share.ShareClient.GetProperties().Value.Quota
                            if ($shareUsageBytes) {
                                $shareUsageGB = [math]::Round($shareUsageBytes / 1GB, 2)
                            }
                        }
                        catch {
                            # Stats not available
                            $shareUsageGB = "N/A"
                        }
                    }
                    
                    # Create report object
                    $reportItem = [PSCustomObject]@{
                        SubscriptionName = $subscription.Name
                        SubscriptionId = $subscription.Id
                        ResourceGroup = $sa.ResourceGroupName
                        StorageAccountName = $sa.StorageAccountName
                        FileShareName = $share.Name
                        Location = $sa.Location
                        Tier = $sa.Sku.Tier
                        QuotaGB = $shareQuota
                        UsageGB = $shareUsageGB
                        BackupEnabled = if ($backupInfo) { "Yes" } else { "No" }
                        BackupVault = if ($backupInfo) { $backupInfo.VaultName } else { "N/A" }
                        BackupStatus = if ($backupInfo) { $backupInfo.ProtectionStatus } else { "Not Protected" }
                        LastBackupTime = if ($backupInfo) { $backupInfo.LastBackupTime } else { "N/A" }
                        SyncEnabled = if ($syncInfo) { "Yes" } else { "No" }
                        SyncServiceName = if ($syncInfo) { $syncInfo.SyncServiceName } else { "N/A" }
                        SyncGroupName = if ($syncInfo) { $syncInfo.SyncGroupName } else { "N/A" }
                        SyncStatus = if ($syncInfo) { $syncInfo.ProvisioningState } else { "Not Synced" }
                    }
                    
                    $report += $reportItem
                }
            }
        }
        catch {
            Write-Warning "Could not retrieve file shares from: $($sa.StorageAccountName) - $($_.Exception.Message)"
        }
    }
}

# Display summary statistics
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "REPORT SUMMARY" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total File Shares Found: $($report.Count)" -ForegroundColor White
Write-Host "Backed Up: $($report | Where-Object { $_.BackupEnabled -eq 'Yes' } | Measure-Object | Select-Object -ExpandProperty Count)" -ForegroundColor Green
Write-Host "Not Backed Up: $($report | Where-Object { $_.BackupEnabled -eq 'No' } | Measure-Object | Select-Object -ExpandProperty Count)" -ForegroundColor Red
Write-Host "Sync Enabled: $($report | Where-Object { $_.SyncEnabled -eq 'Yes' } | Measure-Object | Select-Object -ExpandProperty Count)" -ForegroundColor Green
Write-Host "Sync Not Enabled: $($report | Where-Object { $_.SyncEnabled -eq 'No' } | Measure-Object | Select-Object -ExpandProperty Count)" -ForegroundColor Yellow
Write-Host "============================================`n" -ForegroundColor Cyan

# Display report on screen
if ($report.Count -gt 0) {
    $report | Format-Table -AutoSize
    
    # Generate output file names with timestamp
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath = Join-Path $OutputPath "AzureFileShareReport_$timestamp.csv"
    $xlsxPath = Join-Path $OutputPath "AzureFileShareReport_$timestamp.xlsx"
    
    # Export to CSV
    Write-Host "Exporting to CSV: $csvPath" -ForegroundColor Cyan
    $report | Export-Csv -Path $csvPath -NoTypeInformation -Force
    Write-Host "CSV export completed successfully!" -ForegroundColor Green
    
    # Export to Excel (if ImportExcel module is available)
    if (Get-Module -ListAvailable -Name ImportExcel) {
        Write-Host "Exporting to Excel: $xlsxPath" -ForegroundColor Cyan
        
        # Create Excel with formatting
        $report | Export-Excel -Path $xlsxPath -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow `
            -ConditionalText @(
                New-ConditionalText -Text "Yes" -ConditionalTextColor Green -BackgroundColor LightGreen -Range "I:I,M:M"
                New-ConditionalText -Text "No" -ConditionalTextColor Red -BackgroundColor LightPink -Range "I:I,M:M"
                New-ConditionalText -Text "Not Protected" -ConditionalTextColor Red -BackgroundColor LightPink -Range "K:K"
            ) -WorksheetName "File Share Report"
        
        Write-Host "Excel export completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Warning "ImportExcel module not available. Excel export skipped. Install with: Install-Module ImportExcel"
    }
    
    Write-Host "`nReport files saved to: $OutputPath" -ForegroundColor Cyan
}
else {
    Write-Host "No Azure File Shares found in the scanned subscription(s)." -ForegroundColor Yellow
}

Write-Host "`nReport generation completed!" -ForegroundColor Green
