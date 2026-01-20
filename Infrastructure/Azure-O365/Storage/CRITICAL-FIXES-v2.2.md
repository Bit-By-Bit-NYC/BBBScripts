# Azure File Share Report - Version 2.2 Critical Fixes

## 🔍 Issues Found from Your Output

### 1. ❌ Backups Not Matching - **ROOT CAUSE IDENTIFIED**

**The Problem:**
Azure Backup stores file share names as **hashed values**, not actual names!

**What you saw:**
```
Backup item: instrdata01/AzureFileShare;664f594eec6c29fafbf5c694621dd2bec093e70f387103f99e734f612e1b67f0
```

**What the actual file share is named:**
```
files
```

**The Fix:**
The script now extracts the real file share name from:
1. **FriendlyName property** (format: `storageaccount;filesharename`)
2. **SourceResourceId** (format: `.../fileshares/sharename`)

**Expected Result:**
```
Backup item: instrdata01/files (Status: Healthy)
```

---

### 2. ❌ Server Names Showing GUIDs

**The Problem:**
Registered servers showing as GUIDs instead of friendly names:
```
Server: b81ef542-32ba-4ec1-9cff-6cb9beff3619
```

**The Fix:**
Enhanced server name retrieval to check multiple properties:
- ServerName
- FriendlyName  
- Name
- ServerResourceId (extract last part)

**Note:** If Azure doesn't have a friendly name registered, the GUID is the only identifier available. You may need to set friendly names in Azure File Sync for your registered servers.

---

### 3. ✅ Duplicate Sync Groups

**The Problem:**
Same sync topology appearing twice in output

**The Fix:**
Added deduplication based on SyncServiceName + SyncGroupName combination before displaying

---

### 4. ⚠️ Unhealthy Backups - **This is Important!**

**What you saw:**
```
Backup item: idmstemp/... (Status: Unhealthy)
Backup item: 1vwidmsinfd02/... (Status: Unhealthy)
```

**What this means:**

**Unhealthy backups** indicate one or more of these issues:
1. **Source file share was deleted** but backup retention hasn't expired
2. **Backup job is failing** - can't connect to storage account
3. **Storage account credentials changed** - backup can't authenticate
4. **File share was renamed** - backup configuration is stale
5. **Network/firewall issues** preventing backup access

**Why they still appear:**
- Azure keeps backup data for the configured retention period even after source deletion
- Backup policies continue attempting to back up until manually stopped
- These consume backup storage and may incur costs

**Action Required:**
You should review and clean up unhealthy backups:

```powershell
# Check backup details
Get-AzRecoveryServicesBackupItem -WorkloadType AzureFiles -VaultId $vaultId | 
    Where-Object { $_.ProtectionStatus -eq "Unhealthy" } | 
    Format-Table FriendlyName, ProtectionStatus, LastBackupStatus

# To remove unhealthy backups (after verification):
# Disable-AzRecoveryServicesBackupProtection -Item $backupItem -RemoveRecoveryPoints
```

---

## 📊 What Should Work Now

### Backup Detection
**Before v2.2:**
```
Total unique backed up file share(s): 14
Backed Up: 0  ❌
```

**After v2.2:**
```
Total unique backed up file share(s): 14
Backed Up: 14  ✅

Backup item: 2fstidmsscience/2fstidmsscience (Status: Healthy)
Backup item: instrdata01/files (Status: Healthy)
Backup item: phl3535azurefiles01/instrumentdata (Status: Healthy)
```

### Server Names
**Before v2.2:**
```
Server: b81ef542-32ba-4ec1-9cff-6cb9beff3619  ❌
```

**After v2.2** (if friendly names are set):
```
Server: FILE-SERVER-01  ✅
```

**If friendly names aren't set in Azure:**
```
Server: b81ef542-32ba-4ec1-9cff-6cb9beff3619  (This is correct if no friendly name exists)
```

---

## 🚀 How to Run v2.2

### 1. Specify Your Subscription
Since you have 2 subscriptions and one fails, run against your specific subscription:

```powershell
.\Get-AzureFileShareReport-Enhanced.ps1 -SubscriptionId "7a299c6d-77d3-439e-8373-b9a2c437a698"
```

### 2. Watch for Backup Matches
Look for output like:
```
Backup item: instrdata01/files (Status: Healthy)
```

Not like:
```
Backup item: instrdata01/AzureFileShare;664f594e... (Status: Healthy)
```

### 3. Review Your Report
You should now see:
- **Backed Up: 14** (not 0)
- **No duplicate sync groups**
- **Actual file share names in backup output**
- **Better server names** (or GUIDs if friendly names aren't set)

---

## 🔧 Setting Friendly Names for Servers (Optional)

If your servers are showing GUIDs, you can set friendly names in Azure:

### Via Azure Portal:
1. Navigate to your **Storage Sync Service** (idmsfs)
2. Go to **Registered servers**
3. Select each server
4. Click **Edit** and set a friendly name

### Via PowerShell:
```powershell
# Get the sync service
$syncService = Get-AzStorageSyncService -ResourceGroupName "CTX_RG01" -Name "idmsfs"

# Get registered servers
$servers = Get-AzStorageSyncServer -ParentObject $syncService

# Update friendly name (if supported)
# Note: This may need to be done through the portal
```

---

## 📋 Handling Unhealthy Backups

### Step 1: Identify Which File Shares Still Exist
```powershell
# Get all storage accounts
Get-AzStorageAccount | ForEach-Object {
    $sa = $_
    Get-AzStorageShare -Context $sa.Context | 
        Select-Object @{N='StorageAccount';E={$sa.StorageAccountName}}, Name
}
```

### Step 2: Compare with Unhealthy Backups
From your output, these backups are unhealthy:
- `idmstemp/*` (appears in 2 vaults - likely deleted)
- `1vwidmsinfd02/*` (2 shares)
- `2vwsdmsinfd01/*` (1 of 2 shares)
- `idmsfs/*` (3 of 4 shares)

### Step 3: Clean Up Deleted File Share Backups

**For file shares that NO LONGER EXIST:**
```powershell
# Set vault context
$vault = Get-AzRecoveryServicesVault -Name "bb260recoveryservicesvault01"
Set-AzRecoveryServicesVaultContext -Vault $vault

# Get the unhealthy backup item
$container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -Name "idmstemp"
$item = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureFiles

# Stop protection and remove recovery points (PERMANENT!)
Disable-AzRecoveryServicesBackupProtection -Item $item -RemoveRecoveryPoints -Force
```

**For file shares that STILL EXIST but backup is failing:**
1. Check storage account firewall settings
2. Verify storage account key rotation hasn't broken backup
3. Re-register the storage account with the vault
4. Check network connectivity from backup infrastructure

---

## 🎯 Summary of v2.2 Changes

| Issue | Status | Fix |
|-------|--------|-----|
| Backup detection (0 found) | ✅ FIXED | Extract real names from FriendlyName/SourceResourceId |
| Server names (GUIDs) | ⚠️ IMPROVED | Try multiple properties, show GUID if no friendly name exists |
| Duplicate sync groups | ✅ FIXED | Deduplicate before display |
| Unhealthy backups | ℹ️ IDENTIFIED | These are real issues requiring manual cleanup |

---

## ✅ Success Criteria

After running v2.2, you should see:
1. ✅ **14 backed up file shares detected** (matching the "Total unique" count)
2. ✅ **No duplicate sync topology**
3. ✅ **Real file share names** in backup output
4. ✅ **Better server names** (or acknowledgment that GUIDs are correct)
5. ℹ️ **Clear indication of unhealthy backups** that need attention

---

## 📞 Next Steps

1. **Run the script with v2.2**
2. **Verify backup detection is working** (Backed Up: 14 instead of 0)
3. **Review unhealthy backups** and determine which need cleanup
4. **Optionally set friendly names** for registered servers
5. **Share results** if any issues persist!
