# Azure File Share Report Script

## Overview
This PowerShell script generates a comprehensive report on all Azure File Shares in your subscription(s), including:
- File Share details (name, storage account, resource group, location, tier, quota)
- **Backup Status** - Whether the file share is protected by Azure Backup
- **Sync Status** - Whether the file share is part of Azure File Sync

## Prerequisites

### Required PowerShell Modules
The script will automatically check and install the following modules if missing:
- `Az.Accounts` - Azure authentication
- `Az.Storage` - Storage account and file share operations
- `Az.RecoveryServices` - Backup status checking
- `Az.StorageSync` - Sync service checking
- `ImportExcel` - Excel export functionality (optional)

### Azure Permissions Required
Your Azure account needs the following permissions:
- **Reader** or higher on subscriptions/resource groups
- Access to view Recovery Services Vaults
- Access to view Storage Sync Services

## Usage

### Basic Usage (Scan all subscriptions)
```powershell
.\Get-AzureFileShareReport.ps1
```

### Scan Specific Subscription
```powershell
.\Get-AzureFileShareReport.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012"
```

### Specify Custom Output Path
```powershell
.\Get-AzureFileShareReport.ps1 -OutputPath "C:\Reports"
```

### Combined Parameters
```powershell
.\Get-AzureFileShareReport.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -OutputPath "C:\AzureReports"
```

## Output

The script provides three types of output:

### 1. Console Display
- Summary statistics (total shares, backup/sync counts)
- Formatted table view of all file shares
- Color-coded status messages

### 2. CSV File
- Filename: `AzureFileShareReport_YYYYMMDD_HHMMSS.csv`
- All data in tabular format
- Can be opened in Excel or imported elsewhere

### 3. Excel File (XLSX)
- Filename: `AzureFileShareReport_YYYYMMDD_HHMMSS.xlsx`
- Formatted spreadsheet with:
  - Auto-sized columns
  - Frozen header row
  - Auto-filter enabled
  - Conditional formatting (Green = Yes/Enabled, Red = No/Not Protected)

## Report Columns

| Column | Description |
|--------|-------------|
| SubscriptionName | Azure subscription name |
| SubscriptionId | Azure subscription ID |
| ResourceGroup | Resource group containing the storage account |
| StorageAccountName | Storage account name |
| FileShareName | File share name |
| Location | Azure region |
| Tier | Storage tier (Standard/Premium) |
| QuotaGB | File share quota in GB |
| **BackupEnabled** | Yes/No - Is backup configured? |
| BackupVault | Name of Recovery Services Vault (if backed up) |
| BackupStatus | Protection status (Protected/Not Protected) |
| LastBackupTime | Timestamp of last successful backup |
| **SyncEnabled** | Yes/No - Is Azure File Sync configured? |
| SyncServiceName | Storage Sync Service name (if synced) |
| SyncGroupName | Sync Group name (if synced) |
| SyncStatus | Provisioning state of sync endpoint |

## Troubleshooting

### Module Installation Issues
If automatic module installation fails:
```powershell
Install-Module -Name Az -Scope CurrentUser -Force
Install-Module -Name ImportExcel -Scope CurrentUser -Force
```

### Authentication Issues
Ensure you're logged in to Azure:
```powershell
Connect-AzAccount
```

To use a specific account:
```powershell
Connect-AzAccount -TenantId "your-tenant-id"
```

### Permission Errors
If you receive permission errors:
1. Verify you have Reader access to the subscription
2. Check that you can view Recovery Services Vaults
3. Confirm access to Storage Sync Services

### Excel Export Not Working
If Excel export fails, ensure the ImportExcel module is installed:
```powershell
Install-Module -Name ImportExcel -Scope CurrentUser -Force
```

## Performance Notes

- Scanning time depends on:
  - Number of subscriptions
  - Number of storage accounts
  - Number of file shares
  - Number of Recovery Services Vaults
  - Number of Storage Sync Services

- Typical scan time: 30 seconds to 5 minutes per subscription

## Examples

### Example 1: Quick Audit
```powershell
# Run script and review results on screen
.\Get-AzureFileShareReport.ps1
```

### Example 2: Scheduled Reporting
```powershell
# Save to specific location for scheduled task
.\Get-AzureFileShareReport.ps1 -OutputPath "C:\Reports\Azure"
```

### Example 3: Multi-Subscription Environment
```powershell
# Script automatically scans all accessible subscriptions
.\Get-AzureFileShareReport.ps1 -OutputPath "\\fileserver\AzureReports"
```

## Sample Output

```
============================================
REPORT SUMMARY
============================================
Total File Shares Found: 15
Backed Up: 10
Not Backed Up: 5
Sync Enabled: 3
Sync Not Enabled: 12
============================================

SubscriptionName  ResourceGroup    StorageAccountName  FileShareName  BackupEnabled  SyncEnabled
----------------  -------------    ------------------  -------------  -------------  -----------
Production        rg-storage-prod  stprodfiles01       documents      Yes            No
Production        rg-storage-prod  stprodfiles01       archives       Yes            Yes
Development       rg-storage-dev   stdevfiles01        testdata       No             No
...
```

## Security Considerations

- The script only performs **READ operations**
- No modifications are made to any Azure resources
- Credentials are handled by Azure PowerShell modules
- Output files may contain sensitive information - store securely

## Support

For issues or questions:
1. Check the Azure PowerShell documentation: https://docs.microsoft.com/powershell/azure/
2. Verify your Azure permissions
3. Review the script's verbose output for specific errors

## Version History

- v1.0 - Initial release
  - Multi-subscription support
  - Backup status checking
  - Sync status checking
  - CSV and Excel export
  - Console summary display
