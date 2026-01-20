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
    
    # Build backup lookup table
    $backupLookup = @{}
    foreach ($vault in $backupVaults) {
        try {
            Set-AzRecoveryServicesVaultContext -Vault $vault
            $backupItems = Get-AzRecoveryServicesBackupItem -WorkloadType AzureFiles -ErrorAction SilentlyContinue
            
            foreach ($item in $backupItems) {
                # Extract storage account and file share name from the backup item
                $key = "$($item.ContainerName)/$($item.Name)"
                $backupLookup[$key] = @{
                    VaultName = $vault.Name
                    ProtectionStatus = $item.ProtectionStatus
                    LastBackupTime = $item.LastBackupTime
                    ProtectionState = $item.ProtectionState
                }
            }
        }
        catch {
            Write-Warning "Could not retrieve backup items from vault: $($vault.Name)"
        }
    }
    
    # Get all Storage Sync Services for sync checking
    Write-Host "  - Retrieving Storage Sync Services..." -ForegroundColor Gray
    $syncServices = Get-AzStorageSyncService -ErrorAction SilentlyContinue
    
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
                foreach ($serverEndpoint in $serverEndpoints) {
                    # Get registered server details
                    $registeredServer = Get-AzStorageSyncServer -ParentObject $syncService | Where-Object { $_.ServerId -eq $serverEndpoint.ServerId }
                    
                    $serverEndpointDetails += @{
                        ServerName = if ($registeredServer) { $registeredServer.FriendlyName } else { "Unknown Server" }
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
            # Get file shares
            $shares = Get-AzStorageShare -Context $sa.Context -ErrorAction SilentlyContinue
            
            if ($shares) {
                foreach ($share in $shares) {
                    # Check backup status
                    $backupKey = "$($sa.StorageAccountName)/$($share.Name)"
                    $backupInfo = $backupLookup[$backupKey]
                    
                    # Check sync status
                    $syncKey = "$($sa.StorageAccountName)/$($share.Name)"
                    $syncInfo = $syncLookup[$syncKey]
                    
                    # Get share properties
                    $shareQuota = $share.Properties.Quota
                    
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
        
        foreach ($item in $syncTopology) {
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
