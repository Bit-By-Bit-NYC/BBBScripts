# Azure File Share Report - Version 2.1 Updates

## Issues Fixed in This Version

### 1. ✅ Duplicate File Shares Removed
**Problem:** Same file shares appearing multiple times in the report  
**Cause:** `Get-AzStorageShare` was returning file share snapshots along with the actual shares  
**Fix:** Added filter `Where-Object { $_.IsSnapshot -eq $false }` to exclude snapshots

**Before:** 148 entries (many duplicates)  
**After:** Only unique file shares listed

---

### 2. ✅ Added Actual Usage Size
**Problem:** Only showing quota, not actual usage  
**New Column:** `UsageGB` - Shows actual storage used in GB  
**Implementation:** 
- Uses `$share.ShareClient.GetStatistics()` to retrieve actual usage
- Falls back to alternative methods if primary fails
- Shows "N/A" if stats unavailable
- Rounded to 2 decimal places

**Example Output:**
```
QuotaGB  UsageGB
-------  -------
5120     3247.56
1024     856.23
100      N/A
```

---

### 3. ✅ Enhanced Backup Detection with Debugging
**Problem:** Backups not being detected even though they exist  
**Improvements:**
- Added detailed diagnostic output showing:
  - Each vault being checked
  - Number of backup containers found
  - Number of backup items in each container
  - Exact storage account/file share names found in backups
  - Total unique backed up shares
- Creates multiple lookup keys (with `/` and `\`) to improve matching
- Better parsing of container names

**New Diagnostic Output:**
```
  - Retrieving Recovery Services Vaults...
    Found 2 Recovery Services Vault(s)
    Checking vault: CTX-Backup-Vault
      Found 3 backup container(s)
        Container: stprodfiles01 has 5 backup item(s)
          Backup item: stprodfiles01/documents (Status: Protected)
          Backup item: stprodfiles01/archives (Status: Protected)
    Total unique backed up file share(s): 8
```

This will help identify:
- If vaults are being found
- If backup containers exist
- What the exact names are in the backup system
- Why matches might be failing

---

## Updated Report Columns

| Column | Type | Description |
|--------|------|-------------|
| SubscriptionName | Text | Azure subscription name |
| SubscriptionId | GUID | Subscription ID |
| ResourceGroup | Text | Resource group |
| StorageAccountName | Text | Storage account |
| FileShareName | Text | File share name |
| Location | Text | Azure region |
| Tier | Text | Standard/Premium |
| **QuotaGB** | Number | **Provisioned quota size** |
| **UsageGB** ⭐ NEW | Number | **Actual storage used** |
| BackupEnabled | Yes/No | Backup configured |
| BackupVault | Text | Vault name |
| BackupStatus | Text | Protection status |
| LastBackupTime | DateTime | Last backup timestamp |
| SyncEnabled | Yes/No | Sync configured |
| SyncServiceName | Text | Sync service |
| SyncGroupName | Text | Sync group |
| SyncStatus | Text | Sync state |

---

## How to Use the Updated Scripts

### 1. Download and Replace
Download the new versions and replace your existing files in:
`~/Projects/BBBScripts/Infrastructure/Azure-O365/Storage/`

### 2. Run with Diagnostic Output
```powershell
.\Get-AzureFileShareReport-Enhanced.ps1 -SubscriptionId "7a299c6d-77d3-439e-8373-b9a2c437a698"
```

### 3. Review Backup Diagnostic Output
Pay attention to the backup vault section:
```
  - Retrieving Recovery Services Vaults...
    Found X Recovery Services Vault(s)
    Checking vault: YourVaultName
      Found X backup container(s)
        ...
```

If you see backup items listed but they're still not matching in the report, **send me the exact output** from this section. I can then adjust the matching logic based on the actual format of your backup data.

---

## Troubleshooting Backups Still Not Showing

If backups are still showing as "No" after running the updated script:

1. **Check the diagnostic output** - Does it show backup items being found?
2. **Compare names carefully** - Look at what the script shows:
   - Backup item name: `storageaccount/sharename`
   - vs. Report showing: `StorageAccountName/FileShareName`
3. **Send me this info:**
   - Copy the "Backup item:" lines from the output
   - Copy a few lines from the report showing those same shares
   - I can then see if there's a name mismatch (case, special characters, etc.)

---

## Example Comparison

### Before (v2.0):
```
StorageAccountName  FileShareName  QuotaGB  UsageGB  BackupEnabled
------------------  -------------  -------  -------  -------------
stprodfiles01       documents               0        No
stprodfiles01       documents               0        No  (duplicate)
stprodfiles01       documents-snap1         0        No  (snapshot)
```

### After (v2.1):
```
StorageAccountName  FileShareName  QuotaGB  UsageGB    BackupEnabled
------------------  -------------  -------  -------    -------------
stprodfiles01       documents      5120     3247.56    Yes
```

---

## What's Next

After running the updated script, the diagnostic output will tell us:
- ✅ If duplicates are gone
- ✅ If usage sizes are showing
- 🔍 Why backups might not be matching (if they still aren't)

Please run the script and share the backup diagnostic section if backups still aren't being detected correctly!
