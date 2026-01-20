<#
.SYNOPSIS
    Generate a report on Azure File Shares with Mermaid diagram for Storage Sync topology

.DESCRIPTION
    This script scans all Azure File Shares across subscriptions and reports:
    - File Share details (name, storage account, resource group)
    - Backup status (whether protected by Azure Backup)
    - Sync status (whether part of Azure File Sync)
    - Generates Mermaid diagrams showing Storage Sync topology
    Output is displayed on screen and exported to CSV, Excel, and Mermaid files

.PARAMETER SubscriptionId
    Optional. Specific subscription ID to scan. If not provided, scans all accessible subscriptions.

.PARAMETER OutputPath
    Optional. Path for output files. Default is current directory.

.PARAMETER GenerateDiagram
    Optional. Generate Mermaid diagram for Storage Sync topology. Default is $true.

.EXAMPLE
    .\Get-AzureFileShareReport-Enhanced.ps1
    
.EXAMPLE
    .\Get-AzureFileShareReport-Enhanced.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -OutputPath "C:\Reports"
#>

param(
    [string]$SubscriptionId,
    [string]$OutputPath = ".",
    [bool]$GenerateDiagram = $true
)

# Function to check if module is installed
function Test-ModuleInstalled {
    param([string]$ModuleName)
    return (Get-Module -ListAvailable -Name $ModuleName)
}

# Function to sanitize node names for Mermaid
function Get-SafeNodeName {
    param([string]$Name)
    # Remove special characters and replace spaces with underscores
    return ($Name -replace '[^a-zA-Z0-9_]', '_')
}

# Function to generate Mermaid diagram for Storage Sync topology
function New-StorageSyncMermaidDiagram {
    param(
        [array]$SyncTopology,
        [string]$OutputPath
    )
    
    if ($SyncTopology.Count -eq 0) {
        Write-Host "No Storage Sync Services found. Skipping diagram generation." -ForegroundColor Yellow
        return
    }
    
    $mermaidContent = @"
graph TB
    classDef syncService fill:#0078D4,stroke:#004578,stroke-width:2px,color:#fff
    classDef syncGroup fill:#50E6FF,stroke:#0078D4,stroke-width:2px,color:#000
    classDef cloudEndpoint fill:#00BCF2,stroke:#0078D4,stroke-width:2px,color:#000
    classDef serverEndpoint fill:#FFB900,stroke:#D83B01,stroke-width:2px,color:#000
    classDef storageAccount fill:#7FBA00,stroke:#498205,stroke-width:2px,color:#000
    
"@
    
    $nodeCounter = 0
    $relationships = @()
    
    foreach ($item in $SyncTopology) {
        # Create safe node IDs
        $syncServiceId = Get-SafeNodeName "SS_$($item.SyncServiceName)"
        $syncGroupId = Get-SafeNodeName "SG_$($item.SyncGroupName)_$nodeCounter"
        
        # Add Sync Service node if not already added
        if ($mermaidContent -notmatch [regex]::Escape($syncServiceId)) {
            $mermaidContent += "    $syncServiceId[""Storage Sync Service<br/>$($item.SyncServiceName)""]:::syncService`n"
        }
        
        # Add Sync Group node
        $mermaidContent += "    $syncGroupId[""Sync Group<br/>$($item.SyncGroupName)""]:::syncGroup`n"
        $relationships += "    $syncServiceId --> $syncGroupId"
        
        # Add Cloud Endpoint (File Share)
        if ($item.CloudEndpoints -and $item.CloudEndpoints.Count -gt 0) {
            foreach ($cloudEndpoint in $item.CloudEndpoints) {
                $cloudEndpointId = Get-SafeNodeName "CE_$($cloudEndpoint.StorageAccountName)_$($cloudEndpoint.FileShareName)_$nodeCounter"
                $storageAccountId = Get-SafeNodeName "SA_$($cloudEndpoint.StorageAccountName)"
                
                # Add Storage Account node if not already added
                if ($mermaidContent -notmatch [regex]::Escape($storageAccountId)) {
                    $mermaidContent += "    $storageAccountId{{""Storage Account<br/>$($cloudEndpoint.StorageAccountName)""}}:::storageAccount`n"
                }
                
                # Add Cloud Endpoint node
                $mermaidContent += "    $cloudEndpointId[(""Cloud Endpoint<br/>File Share: $($cloudEndpoint.FileShareName)"")]:::cloudEndpoint`n"
                $relationships += "    $syncGroupId --> $cloudEndpointId"
                $relationships += "    $cloudEndpointId -.-> $storageAccountId"
            }
        }
        
        # Add Server Endpoints (Registered Servers)
        if ($item.ServerEndpoints -and $item.ServerEndpoints.Count -gt 0) {
            foreach ($serverEndpoint in $item.ServerEndpoints) {
                $serverEndpointId = Get-SafeNodeName "SE_$($serverEndpoint.ServerName)_$($serverEndpoint.ServerLocalPath)_$nodeCounter"
                
                $serverPath = $serverEndpoint.ServerLocalPath
                if ($serverPath.Length -gt 30) {
                    $serverPath = $serverPath.Substring(0, 27) + "..."
                }
                
                # Add Server Endpoint node
                $mermaidContent += "    $serverEndpointId[/""Server Endpoint<br/>$($serverEndpoint.ServerName)<br/>$serverPath""\]:::serverEndpoint`n"
                $relationships += "    $syncGroupId --> $serverEndpointId"
            }
        }
        
        $nodeCounter++
    }
    
    # Add all relationships at the end
    $mermaidContent += "`n"
    foreach ($rel in $relationships) {
        $mermaidContent += "$rel`n"
    }
    
    # Add legend
    $mermaidContent += @"

    subgraph Legend
        L1[Storage Sync Service]:::syncService
        L2[Sync Group]:::syncGroup
        L3[Cloud Endpoint]:::cloudEndpoint
        L4[Server Endpoint]:::serverEndpoint
        L5{{Storage Account}}:::storageAccount
    end
"@
    
    return $mermaidContent
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

# Initialize report array and sync topology array
$report = @()
$syncTopology = @()

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
                        $containerParts = $container.Name -split ';'
                        $storageAccountName = if ($containerParts.Count -ge 4) { $containerParts[3] } else { $container.FriendlyName }
                        
                        # DEBUG: Show all available properties
                        Write-Host "          DEBUG - Backup Item Properties:" -ForegroundColor Cyan
                        Write-Host "            Name: $($item.Name)" -ForegroundColor Gray
                        Write-Host "            FriendlyName: $($item.FriendlyName)" -ForegroundColor Gray
                        Write-Host "            ContainerName: $($item.ContainerName)" -ForegroundColor Gray
                        Write-Host "            WorkloadType: $($item.WorkloadType)" -ForegroundColor Gray
                        if ($item.SourceResourceId) {
                            Write-Host "            SourceResourceId: $($item.SourceResourceId)" -ForegroundColor Gray
                        } else {
                            Write-Host "            SourceResourceId: <null>" -ForegroundColor Gray
                        }
                        
                        # Get actual file share name
                        $fileShareName = $null
                        
                        # Try FriendlyName (format: storageaccount;filesharename)
                        if ($item.FriendlyName -and $item.FriendlyName -match ';') {
                            $friendlyParts = $item.FriendlyName -split ';'
                            if ($friendlyParts.Count -ge 2) {
                                $fileShareName = $friendlyParts[1]
                                Write-Host "            Extracted from FriendlyName: $fileShareName" -ForegroundColor Green
                            }
                        }
                        
                        # Try SourceResourceId
                        if (-not $fileShareName -and $item.SourceResourceId) {
                            if ($item.SourceResourceId -match '/fileshares/([^/]+)$') {
                                $fileShareName = $matches[1]
                                Write-Host "            Extracted from SourceResourceId: $fileShareName" -ForegroundColor Green
                            }
                        }
                        
                        # Skip if we couldn't determine
                        if (-not $fileShareName) {
                            Write-Host "          Could not determine file share name" -ForegroundColor Yellow
                            continue
                        }
                        
                        Write-Host "          Backup item: $storageAccountName/$fileShareName (Status: $($item.ProtectionStatus))" -ForegroundColor Gray
                        
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
    
    # Build sync lookup table and topology data
    $syncLookup = @{}
    foreach ($syncService in $syncServices) {
        try {
            $syncGroups = Get-AzStorageSyncGroup -ParentObject $syncService -ErrorAction SilentlyContinue
            
            foreach ($syncGroup in $syncGroups) {
                # Get Cloud Endpoints
                $cloudEndpoints = Get-AzStorageSyncCloudEndpoint -ParentObject $syncGroup -ErrorAction SilentlyContinue
                
                # Get Server Endpoints (Registered Servers)
                $serverEndpoints = Get-AzStorageSyncServerEndpoint -ParentObject $syncGroup -ErrorAction SilentlyContinue
                
                # Build topology object
                $cloudEndpointDetails = @()
                foreach ($endpoint in $cloudEndpoints) {
                    if ($endpoint.StorageAccountResourceId -and $endpoint.AzureFileShareName) {
                        $storageAccountName = ($endpoint.StorageAccountResourceId -split '/')[-1]
                        $key = "$storageAccountName/$($endpoint.AzureFileShareName)"
                        
                        $syncLookup[$key] = @{
                            SyncServiceName = $syncService.StorageSyncServiceName
                            SyncGroupName = $syncGroup.SyncGroupName
                            ProvisioningState = $endpoint.ProvisioningState
                        }
                        
                        $cloudEndpointDetails += @{
                            StorageAccountName = $storageAccountName
                            FileShareName = $endpoint.AzureFileShareName
                            ProvisioningState = $endpoint.ProvisioningState
                        }
                    }
                }
                
                # Build server endpoint details
                $serverEndpointDetails = @()
                
                # Get all registered servers for this sync service
                $registeredServers = @()
                try {
                    Write-Host "      DEBUG - Getting registered servers..." -ForegroundColor Cyan
                    $registeredServers = Get-AzStorageSyncServer -ParentObject $syncService -ErrorAction SilentlyContinue
                    Write-Host "      Found $($registeredServers.Count) registered server(s)" -ForegroundColor Gray
                } catch {
                    Write-Warning "Could not retrieve registered servers for sync service: $($syncService.StorageSyncServiceName)"
                }
                
                foreach ($serverEndpoint in $serverEndpoints) {
                    Write-Host "      DEBUG - Server Endpoint Properties:" -ForegroundColor Cyan
                    Write-Host "        ServerId: $($serverEndpoint.ServerId)" -ForegroundColor Gray
                    Write-Host "        ServerResourceId: $($serverEndpoint.ServerResourceId)" -ForegroundColor Gray
                    Write-Host "        ServerLocalPath: $($serverEndpoint.ServerLocalPath)" -ForegroundColor Gray
                    
                    # Try to find the registered server by ServerId
                    $registeredServer = $registeredServers | Where-Object { $_.ServerId -eq $serverEndpoint.ServerId } | Select-Object -First 1
                    
                    if ($registeredServer) {
                        Write-Host "      DEBUG - Registered Server Properties:" -ForegroundColor Cyan
                        Write-Host "        ServerId: $($registeredServer.ServerId)" -ForegroundColor Gray
                        Write-Host "        Name: $($registeredServer.Name)" -ForegroundColor Gray
                        Write-Host "        FriendlyName: $($registeredServer.FriendlyName)" -ForegroundColor Gray
                        Write-Host "        ServerName: $($registeredServer.ServerName)" -ForegroundColor Gray
                        Write-Host "        ServerResourceId: $($registeredServer.ServerResourceId)" -ForegroundColor Gray
                        
                        # Try to get all properties
                        $allProps = $registeredServer | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name
                        Write-Host "        All Properties: $($allProps -join ', ')" -ForegroundColor Gray
                    } else {
                        Write-Host "      No matching registered server found" -ForegroundColor Yellow
                    }
                    
                    # Determine server name
                    $serverName = $null
                    
                    if ($registeredServer) {
                        if ($registeredServer.ServerName) {
                            $serverName = $registeredServer.ServerName
                        } elseif ($registeredServer.FriendlyName) {
                            $serverName = $registeredServer.FriendlyName
                        } elseif ($registeredServer.Name) {
                            $serverName = $registeredServer.Name
                        } elseif ($registeredServer.ServerResourceId) {
                            $parts = $registeredServer.ServerResourceId -split '/'
                            $serverName = $parts[-1]
                        }
                    }
                    
                    if (-not $serverName -and $serverEndpoint.ServerResourceId) {
                        $parts = $serverEndpoint.ServerResourceId -split '/'
                        $serverName = $parts[-1]
                    }
                    
                    if (-not $serverName) {
                        $serverName = $serverEndpoint.ServerId
                    }
                    
                    Write-Host "      Final Server Name: $serverName" -ForegroundColor Green
                    
                    $serverEndpointDetails += @{
                        ServerName = $serverName
                        ServerId = $serverEndpoint.ServerId
                        ServerLocalPath = $serverEndpoint.ServerLocalPath
                        CloudTiering = $serverEndpoint.CloudTiering
                        VolumeFreeSpacePercent = $serverEndpoint.VolumeFreeSpacePercent
                        TierFilesOlderThanDays = $serverEndpoint.TierFilesOlderThanDays
                        ProvisioningState = $serverEndpoint.ProvisioningState
                    }
                }
                
                # Add to topology
                $syncTopology += [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    SyncServiceName = $syncService.StorageSyncServiceName
                    SyncServiceResourceGroup = $syncService.ResourceGroupName
                    SyncGroupName = $syncGroup.SyncGroupName
                    CloudEndpoints = $cloudEndpointDetails
                    ServerEndpoints = $serverEndpointDetails
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
            # Check if storage account has restrictive network rules
            $hasNetworkRestrictions = $false
            if ($sa.NetworkRuleSet -and $sa.NetworkRuleSet.DefaultAction -eq "Deny") {
                $hasNetworkRestrictions = $true
                Write-Host "      WARNING: Storage account has network restrictions (DefaultAction: Deny)" -ForegroundColor Yellow
            }
            
            # Get file shares
            $shares = $null
            try {
                $shares = Get-AzStorageShare -Context $sa.Context -ErrorAction Stop | Where-Object { $_.IsSnapshot -eq $false }
            }
            catch {
                if ($_.Exception.Message -match "AuthorizationFailure|AuthenticationFailed|network|firewall|403|blocked") {
                    Write-Host "      ERROR: Cannot access file shares - Network/Firewall restriction" -ForegroundColor Red
                    Write-Host "      This storage account's firewall is blocking access from your current IP" -ForegroundColor Red
                    Write-Host "      Storage Account: $($sa.StorageAccountName) may have file shares that are not in this report" -ForegroundColor Red
                    
                    # Try to get file share info from sync topology if available
                    $syncSharesForThisAccount = $syncLookup.Keys | Where-Object { $_ -like "$($sa.StorageAccountName)/*" }
                    if ($syncSharesForThisAccount) {
                        Write-Host "      Found in Sync Topology:" -ForegroundColor Yellow
                        foreach ($syncKey in $syncSharesForThisAccount) {
                            $parts = $syncKey -split '/'
                            $shareName = $parts[1]
                            Write-Host "        - File Share: $shareName (from Sync data)" -ForegroundColor Yellow
                            
                            # Add to report with limited info
                            $reportItem = [PSCustomObject]@{
                                SubscriptionName = $subscription.Name
                                SubscriptionId = $subscription.Id
                                ResourceGroup = $sa.ResourceGroupName
                                StorageAccountName = $sa.StorageAccountName
                                FileShareName = $shareName
                                Location = $sa.Location
                                Tier = $sa.Sku.Tier
                                QuotaGB = "Unknown"
                                UsageGB = "Restricted"
                                BackupEnabled = if ($backupLookup["$($sa.StorageAccountName)/$shareName"]) { "Yes" } else { "Unknown" }
                                BackupVault = if ($backupLookup["$($sa.StorageAccountName)/$shareName"]) { $backupLookup["$($sa.StorageAccountName)/$shareName"].VaultName } else { "Unknown" }
                                BackupStatus = if ($backupLookup["$($sa.StorageAccountName)/$shareName"]) { $backupLookup["$($sa.StorageAccountName)/$shareName"].ProtectionStatus } else { "Network Restricted" }
                                LastBackupTime = if ($backupLookup["$($sa.StorageAccountName)/$shareName"]) { $backupLookup["$($sa.StorageAccountName)/$shareName"].LastBackupTime } else { "N/A" }
                                SyncEnabled = "Yes"
                                SyncServiceName = $syncLookup["$($sa.StorageAccountName)/$shareName"].SyncServiceName
                                SyncGroupName = $syncLookup["$($sa.StorageAccountName)/$shareName"].SyncGroupName
                                SyncStatus = $syncLookup["$($sa.StorageAccountName)/$shareName"].ProvisioningState
                            }
                            $report += $reportItem
                        }
                    }
                    continue
                }
                throw
            }
            
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
Write-Host "Storage Sync Services: $($syncTopology | Select-Object -Unique SyncServiceName | Measure-Object | Select-Object -ExpandProperty Count)" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Display report on screen
if ($report.Count -gt 0) {
    $report | Format-Table -AutoSize
    
    # Generate output file names with timestamp
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath = Join-Path $OutputPath "AzureFileShareReport_$timestamp.csv"
    $xlsxPath = Join-Path $OutputPath "AzureFileShareReport_$timestamp.xlsx"
    $mermaidPath = Join-Path $OutputPath "AzureFileSyncTopology_$timestamp.mmd"
    $mermaidHtmlPath = Join-Path $OutputPath "AzureFileSyncTopology_$timestamp.html"
    
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
    
    # Generate Mermaid diagram for Storage Sync topology
    if ($GenerateDiagram -and $syncTopology.Count -gt 0) {
        Write-Host "`nGenerating Storage Sync topology diagram..." -ForegroundColor Cyan
        
        $mermaidDiagram = New-StorageSyncMermaidDiagram -SyncTopology $syncTopology -OutputPath $OutputPath
        
        # Save Mermaid file
        $mermaidDiagram | Out-File -FilePath $mermaidPath -Encoding UTF8 -Force
        Write-Host "Mermaid diagram saved: $mermaidPath" -ForegroundColor Green
        
        # Create HTML file with Mermaid renderer
        $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Azure File Sync Topology</title>
    <script type="module">
        import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs';
        mermaid.initialize({ startOnLoad: true, theme: 'default', securityLevel: 'loose' });
    </script>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        h1 {
            color: #0078D4;
            text-align: center;
        }
        .container {
            background-color: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .mermaid {
            text-align: center;
        }
        .info {
            background-color: #E8F4FD;
            border-left: 4px solid #0078D4;
            padding: 15px;
            margin: 20px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Azure File Sync Topology Diagram</h1>
        <div class="info">
            <strong>Generated:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")<br/>
            <strong>Subscriptions Scanned:</strong> $($subscriptions.Count)<br/>
            <strong>Storage Sync Services:</strong> $($syncTopology | Select-Object -Unique SyncServiceName | Measure-Object | Select-Object -ExpandProperty Count)
        </div>
        <div class="mermaid">
$mermaidDiagram
        </div>
    </div>
</body>
</html>
"@
        
        $htmlContent | Out-File -FilePath $mermaidHtmlPath -Encoding UTF8 -Force
        Write-Host "HTML diagram saved: $mermaidHtmlPath" -ForegroundColor Green
        Write-Host "Open the HTML file in a web browser to view the interactive diagram." -ForegroundColor Yellow
        
        # Display sync topology details
        Write-Host "`n============================================" -ForegroundColor Cyan
        Write-Host "STORAGE SYNC TOPOLOGY DETAILS" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        
        # Deduplicate topology by SyncService + SyncGroup
        $uniqueTopology = $syncTopology | Group-Object -Property SyncServiceName, SyncGroupName | ForEach-Object { $_.Group | Select-Object -First 1 }
        
        foreach ($item in $uniqueTopology) {
            Write-Host "`nSync Service: $($item.SyncServiceName) (RG: $($item.SyncServiceResourceGroup))" -ForegroundColor Yellow
            Write-Host "  Sync Group: $($item.SyncGroupName)" -ForegroundColor Cyan
            
            if ($item.CloudEndpoints) {
                Write-Host "  Cloud Endpoints:" -ForegroundColor Green
                foreach ($ce in $item.CloudEndpoints) {
                    Write-Host "    - Storage Account: $($ce.StorageAccountName)" -ForegroundColor White
                    Write-Host "      File Share: $($ce.FileShareName)" -ForegroundColor White
                    Write-Host "      State: $($ce.ProvisioningState)" -ForegroundColor Gray
                }
            }
            
            if ($item.ServerEndpoints) {
                Write-Host "  Server Endpoints:" -ForegroundColor Magenta
                foreach ($se in $item.ServerEndpoints) {
                    Write-Host "    - Server: $($se.ServerName)" -ForegroundColor White
                    Write-Host "      Path: $($se.ServerLocalPath)" -ForegroundColor White
                    Write-Host "      Cloud Tiering: $($se.CloudTiering)" -ForegroundColor Gray
                    if ($se.CloudTiering -eq "Enabled") {
                        Write-Host "      Volume Free Space: $($se.VolumeFreeSpacePercent)%" -ForegroundColor Gray
                        Write-Host "      Tier Files Older Than: $($se.TierFilesOlderThanDays) days" -ForegroundColor Gray
                    }
                    Write-Host "      State: $($se.ProvisioningState)" -ForegroundColor Gray
                }
            }
        }
        Write-Host "============================================`n" -ForegroundColor Cyan
    }
    
    Write-Host "`nReport files saved to: $OutputPath" -ForegroundColor Cyan
}
else {
    Write-Host "No Azure File Shares found in the scanned subscription(s)." -ForegroundColor Yellow
}

Write-Host "`nReport generation completed!" -ForegroundColor Green
