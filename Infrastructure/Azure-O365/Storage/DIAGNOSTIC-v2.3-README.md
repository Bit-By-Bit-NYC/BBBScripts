# Diagnostic Version - v2.3 DEBUG

## What This Version Does

This is a **DIAGNOSTIC** version that will reveal exactly what data is available from Azure so we can fix the remaining issues.

## Three Critical Issues to Diagnose

### 1. 🔍 Backup File Share Names
**Issue:** Getting "Could not determine file share name" for all backups

**What the diagnostic will show:**
```
DEBUG - Backup Item Properties:
  Name: AzureFileShare;664f594eec6c29fafbf5c694621dd2bec093e70f387103f99e734f612e1b67f0
  FriendlyName: <whatever Azure provides>
  ContainerName: <container name>
  WorkloadType: AzureFiles
  SourceResourceId: <resource ID if available>
```

This will tell us which property actually contains the file share name so we can extract it.

---

### 2. 🔍 Server Names (GUIDs)
**Issue:** Showing `b81ef542-32ba-4ec1-9cff-6cb9beff3619` instead of server names

**What the diagnostic will show:**
```
DEBUG - Registered Server Properties:
  ServerId: b81ef542-32ba-4ec1-9cff-6cb9beff3619
  Name: <name property>
  FriendlyName: <friendly name property>
  ServerName: <server name property>
  ServerResourceId: <resource ID>
  All Properties: <complete list of available properties>
```

This will show us:
- If server names are even available in Azure
- Which property contains the actual server name
- If we need to set friendly names manually in Azure Portal

---

### 3. 🔍 Missing `idmsfs` Storage Account
**Issue:** The `idmsfs` storage account (with file share `idms`) is not in the report

**Root Cause IDENTIFIED:**
Your `idmsfs` storage account has **very restrictive network rules**:
```json
"networkAcls": {
    "defaultAction": "Deny"
}
```

This blocks PowerShell from accessing it unless you're running from:
- An approved VNet subnet
- One of the approved IP addresses (63.65.130.70, etc.)

**What the diagnostic will show:**
```
- Checking storage account: idmsfs
  WARNING: Storage account has network restrictions (DefaultAction: Deny)
  ERROR: Cannot access file shares - Network/Firewall restriction
  This storage account's firewall is blocking access from your current IP
  Found in Sync Topology:
    - File Share: idms (from Sync data)
```

**The Fix:**
The diagnostic version will now:
1. Detect when a storage account is network-restricted
2. Pull file share info from the Sync Topology instead
3. Add it to the report with a note that it's network-restricted

---

## How to Run the Diagnostic

```powershell
.\Get-AzureFileShareReport-Enhanced.ps1 -SubscriptionId "7a299c6d-77d3-439e-8373-b9a2c437a698"
```

## What to Look For

### 1. Backup Items Section
Look for this in the output:
```
DEBUG - Backup Item Properties:
  Name: ...
  FriendlyName: ...
  SourceResourceId: ...
```

**Copy and send me:**
- The complete DEBUG output for 2-3 backup items
- This will tell me which property has the real file share name

### 2. Server Endpoints Section
Look for this:
```
DEBUG - Registered Server Properties:
  All Properties: <list of properties>
```

**Copy and send me:**
- The complete DEBUG output for one server
- The "All Properties" line especially
- This will tell me if server names are available

### 3. Storage Account Access
Look for:
```
- Checking storage account: idmsfs
  WARNING: Storage account has network restrictions
```

**Expected:** The `idmsfs` file share should now appear in your report with:
- QuotaGB: "Unknown"
- UsageGB: "Restricted"
- BackupEnabled: Yes/Unknown (depending on what we find)
- SyncEnabled: Yes

---

## Expected Report After Diagnostic Run

You should now see **12 file shares** instead of 11:
1. All 11 previously found shares
2. **NEW:** `idmsfs/idms` (marked as network-restricted)

---

## Why This Approach

Rather than guessing which properties contain the data, this diagnostic will **show us exactly what Azure provides**, then we can update the script to extract from the correct properties.

---

## Network Restriction Solutions (for idmsfs)

### Option 1: Run from Approved Location
Run the script from a VM or machine that's in one of these locations:
- Inside VNet: `BB_Lab_Network` or `CTX_Vnet`
- From one of the approved IPs: `63.65.130.70`, `209.160.208.30`, etc.

### Option 2: Temporarily Add Your IP
```powershell
# Get your public IP
$myIP = (Invoke-WebRequest -Uri "https://api.ipify.org").Content

# Add to storage account firewall
$sa = Get-AzStorageAccount -ResourceGroupName "CTX_RG01" -Name "idmsfs"
Add-AzStorageAccountNetworkRule -ResourceGroupName "CTX_RG01" -Name "idmsfs" -IPAddressOrRange $myIP

# Run the script
.\Get-AzureFileShareReport-Enhanced.ps1 -SubscriptionId "7a299c6d-77d3-439e-8373-b9a2c437a698"

# Remove your IP when done (optional)
Remove-AzStorageAccountNetworkRule -ResourceGroupName "CTX_RG01" -Name "idmsfs" -IPAddressOrRange $myIP
```

### Option 3: Use What Sync Topology Provides (Current Approach)
The diagnostic version will extract `idmsfs/idms` from the sync topology data, so you'll see it in the report even though we can't directly access the storage account.

---

## Next Steps

1. **Run the diagnostic version**
2. **Send me the DEBUG output** for:
   - At least 2 backup items
   - At least 1 server endpoint
3. **I'll create the final fix** based on what properties are actually available
4. **Check if `idmsfs` appears** in your report (it should now!)

Let me know what you see!
