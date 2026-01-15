#!/bin/bash

# Script to list Azure Storage Account File Shares and their backup status
# Checks for Azure Backup via Recovery Services Vault
# Usage: Paste this into Azure Cloud Shell (Bash)

# Clean up old CSV files from previous runs
rm -f /tmp/azure_fileshare_backup_*.csv 2>/dev/null

echo "=========================================="
echo "Azure File Shares - Backup Analysis"
echo "=========================================="
echo ""

# List available subscriptions
echo "Available subscriptions:"
echo ""
az account list --query "[].{Name:name, ID:id}" -o table

echo ""
echo "Current subscription:"
az account show --query "{Name:name, ID:id}" -o table

echo ""
read -p "Enter subscription ID or name (or press Enter to use current): " sub_input

if [ ! -z "$sub_input" ]; then
    echo "Setting subscription to: $sub_input"
    az account set --subscription "$sub_input"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to set subscription. Exiting."
        exit 1
    fi
    
    echo "Current subscription is now:"
    az account show --query "{Name:name, ID:id}" -o table
fi

echo ""
echo "=========================================="
echo ""

# Get current subscription details
CURRENT_SUB_NAME=$(az account show --query 'name' -o tsv)
TENANT_NAME=$(az account show --query 'tenantDisplayName' -o tsv 2>/dev/null | tr ' ' '_' | tr -cd '[:alnum:]_-')

# Fallback to tenant ID if name not available
if [ -z "$TENANT_NAME" ]; then
    TENANT_NAME=$(az account show --query 'tenantId' -o tsv 2>/dev/null)
fi

echo "Step 1: Finding all storage accounts with file shares..."
echo ""

# Get all storage accounts
storage_accounts=$(az storage account list --query "[].{Name:name, ResourceGroup:resourceGroup, Location:location}" -o json)
sa_count=$(echo "$storage_accounts" | jq '. | length')

echo "Found $sa_count storage account(s) to check"
echo ""

echo "Step 2: Getting all protected file shares from Recovery Services Vaults..."
echo ""

# Get all Recovery Services Vaults and their protected items
protected_shares_list="/tmp/protected_shares.txt"
> "$protected_shares_list"

vaults=$(az backup vault list --query "[].{Name:name, ResourceGroup:resourceGroup}" -o json 2>/dev/null)
vault_count=$(echo "$vaults" | jq '. | length' 2>/dev/null)

if [ "$vault_count" -gt 0 ]; then
    echo "Found $vault_count Recovery Services Vault(s)"
    
    echo "$vaults" | jq -c '.[]' | while read -r vault; do
        vault_name=$(echo "$vault" | jq -r '.Name')
        vault_rg=$(echo "$vault" | jq -r '.ResourceGroup')
        
        echo "  Checking vault: $vault_name"
        
        # Get protected file shares in this vault
        protected_items=$(az backup item list \
            --resource-group "$vault_rg" \
            --vault-name "$vault_name" \
            --backup-management-type AzureStorage \
            --workload-type AzureFileShare \
            --query "[].{StorageAccount:properties.sourceResourceId, ShareName:properties.friendlyName, ProtectionState:properties.protectionState, LastBackup:properties.lastBackupTime}" \
            -o json 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            echo "$protected_items" | jq -c '.[]' | while read -r item; do
                storage_account_id=$(echo "$item" | jq -r '.StorageAccount')
                share_name=$(echo "$item" | jq -r '.ShareName')
                protection_state=$(echo "$item" | jq -r '.ProtectionState')
                last_backup=$(echo "$item" | jq -r '.LastBackup')
                
                # Extract storage account name from resource ID
                storage_account_name=$(echo "$storage_account_id" | awk -F'/' '{print $9}')
                
                echo "$storage_account_name|$share_name|$protection_state|$last_backup|$vault_name" >> "$protected_shares_list"
            done
        fi
    done
    echo ""
else
    echo "No Recovery Services Vaults found in subscription"
    echo ""
fi

echo "Step 3: Analyzing all file shares..."
echo ""

# Create temp file for results
> /tmp/fileshare_table.txt

total_shares=0
backed_up_shares=0
not_backed_up_shares=0

# Process each storage account
echo "$storage_accounts" | jq -c '.[]' | while read -r sa; do
    sa_name=$(echo "$sa" | jq -r '.Name')
    rg=$(echo "$sa" | jq -r '.ResourceGroup')
    location=$(echo "$sa" | jq -r '.Location')
    
    # Get storage account key
    sa_key=$(az storage account keys list -g "$rg" -n "$sa_name" --query '[0].value' -o tsv 2>/dev/null)
    
    if [ -z "$sa_key" ]; then
        continue
    fi
    
    # List file shares in this storage account
    shares=$(az storage share list \
        --account-name "$sa_name" \
        --account-key "$sa_key" \
        -o json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$(echo "$shares" | jq '. | length')" -gt 0 ]; then
        echo "──────────────────────────────────────"
        echo "Storage Account: $sa_name"
        echo "Resource Group: $rg"
        echo "Location: $location"
        echo "──────────────────────────────────────"
        
        echo "$shares" | jq -c '.[]' | while read -r share; do
            share_name=$(echo "$share" | jq -r '.name')
            
            # Get quota - try multiple possible property paths
            quota_gb=$(echo "$share" | jq -r '.properties.shareQuota // .quota // .properties.quota // 0')
            if [ "$quota_gb" == "null" ] || [ "$quota_gb" == "0" ]; then
                # Try getting share properties directly
                share_props=$(az storage share show \
                    --name "$share_name" \
                    --account-name "$sa_name" \
                    --account-key "$sa_key" \
                    -o json 2>/dev/null)
                quota_gb=$(echo "$share_props" | jq -r '.properties.shareQuota // .quota // 0')
            fi
            
            # Get share usage (used capacity)
            # Try method 1: az storage share stats (fast but may return 0)
            share_stats=$(az storage share stats \
                --name "$share_name" \
                --account-name "$sa_name" \
                --account-key "$sa_key" \
                2>/dev/null)
            
            if [ $? -eq 0 ] && [ ! -z "$share_stats" ]; then
                # az storage share stats returns usage in GB as a simple number
                # Extract just the number using sed (Mac-compatible)
                usage_gb=$(echo "$share_stats" | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)
            else
                usage_gb=""
            fi
            
            # If stats returned 0 or failed, try method 2: Azure Monitor metrics
            if [ -z "$usage_gb" ] || [ "$usage_gb" == "0" ]; then
                # Get subscription ID for the metrics query
                sub_id=$(az account show --query id -o tsv)
                
                # Try to get file share capacity via metrics (last 1 hour)
                capacity_bytes=$(az monitor metrics list \
                    --resource "/subscriptions/$sub_id/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$sa_name/fileServices/default" \
                    --metric "FileCapacity" \
                    --start-time $(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
                    --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
                    --interval PT1H \
                    --aggregation Average \
                    --filter "FileShare eq '$share_name'" \
                    --query 'value[0].timeseries[0].data[-1].average' -o tsv 2>/dev/null)
                
                if [ ! -z "$capacity_bytes" ] && [ "$capacity_bytes" != "null" ] && [ "$capacity_bytes" != "" ]; then
                    # Convert bytes to GB
                    usage_gb=$(awk "BEGIN {printf \"%.2f\", $capacity_bytes / 1073741824}")
                    # Round to nearest integer for display
                    usage_gb=$(printf "%.0f" "$usage_gb")
                fi
            fi
            
            # Final fallback
            if [ -z "$usage_gb" ]; then
                usage_gb="0"
            fi
            
            # Check if this share is protected
            backup_info=$(grep "^${sa_name}|${share_name}|" "$protected_shares_list" 2>/dev/null)
            
            if [ ! -z "$backup_info" ]; then
                # Share is backed up
                protection_state=$(echo "$backup_info" | cut -d'|' -f3)
                last_backup=$(echo "$backup_info" | cut -d'|' -f4)
                vault_name=$(echo "$backup_info" | cut -d'|' -f5)
                backup_status="Yes"
                
                echo "  ✓ File Share: $share_name"
                echo "    Quota: ${quota_gb} GB"
                echo "    Used: ${usage_gb} GB"
                echo "    Backup: ✓ ENABLED"
                echo "    Vault: $vault_name"
                echo "    State: $protection_state"
                if [ "$last_backup" != "null" ] && [ ! -z "$last_backup" ]; then
                    echo "    Last Backup: $last_backup"
                else
                    echo "    Last Backup: No backup yet"
                fi
            else
                # Share is NOT backed up
                backup_status="No"
                protection_state="NotProtected"
                last_backup="N/A"
                vault_name="None"
                
                echo "  ✗ File Share: $share_name"
                echo "    Quota: ${quota_gb} GB"
                echo "    Used: ${usage_gb} GB"
                echo "    Backup: ✗ NOT ENABLED"
                echo "    ⚠ WARNING: This file share has no backup configured!"
            fi
            
            # Ensure we have numeric values for the table (use 0 if empty)
            if [ -z "$quota_gb" ] || [ "$quota_gb" == "null" ]; then
                quota_gb="0"
            fi
            if [ -z "$usage_gb" ] || [ "$usage_gb" == "null" ]; then
                usage_gb="0"
            fi
            
            # Write to table
            echo "$sa_name|$rg|$location|$share_name|$quota_gb|$usage_gb|$backup_status|$protection_state|$last_backup|$vault_name" >> /tmp/fileshare_table.txt
            
            echo ""
        done
    fi
done

echo ""
echo "=========================================="
echo "SUMMARY TABLE - ALL FILE SHARES"
echo "=========================================="
echo ""

# Display the table
if [ -f /tmp/fileshare_table.txt ] && [ -s /tmp/fileshare_table.txt ]; then
    # Create CSV file
    CLEAN_SUB_NAME=$(echo "$CURRENT_SUB_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    CSV_FILE="azure_fileshare_backup_${TENANT_NAME}_${CLEAN_SUB_NAME}_$(date +%Y%m%d_%H%M%S).csv"
    
    # Write CSV header
    echo "Subscription Name,Storage Account,Resource Group,Location,File Share,Quota (GB),Used Capacity (GB),Backup Enabled,Protection State,Last Backup,Recovery Vault" > "/tmp/$CSV_FILE"
    
    # Write CSV data
    while IFS='|' read -r sa_name rg location share_name quota usage backup_status protection_state last_backup vault; do
        echo "\"$CURRENT_SUB_NAME\",\"$sa_name\",\"$rg\",\"$location\",\"$share_name\",$quota,\"$usage\",\"$backup_status\",\"$protection_state\",\"$last_backup\",\"$vault\"" >> "/tmp/$CSV_FILE"
    done < /tmp/fileshare_table.txt
    
    echo "CSV file created: $CSV_FILE"
    echo ""
    
    # Display table
    printf "%-30s %-30s %-15s %-10s %-15s %-15s %-20s\n" "STORAGE ACCOUNT" "FILE SHARE" "QUOTA (GB)" "USED (GB)" "BACKUP" "PROTECTION" "RECOVERY VAULT"
    printf "%-30s %-30s %-15s %-10s %-15s %-15s %-20s\n" "$(printf '%0.s─' {1..30})" "$(printf '%0.s─' {1..30})" "$(printf '%0.s─' {1..15})" "$(printf '%0.s─' {1..10})" "$(printf '%0.s─' {1..15})" "$(printf '%0.s─' {1..15})" "$(printf '%0.s─' {1..20})"
    
    while IFS='|' read -r sa_name rg location share_name quota usage backup_status protection_state last_backup vault; do
        # Format the display values
        display_quota="$quota"
        display_usage="$usage"
        
        # Show 0 instead of blank
        if [ "$display_quota" == "0" ] || [ -z "$display_quota" ]; then
            display_quota="0"
        fi
        if [ "$display_usage" == "0" ] || [ -z "$display_usage" ]; then
            display_usage="0"
        fi
        
        printf "%-30s %-30s %-15s %-10s %-15s %-15s %-20s\n" "$sa_name" "$share_name" "$display_quota" "$display_usage" "$backup_status" "$protection_state" "$vault"
    done < /tmp/fileshare_table.txt
    
    echo ""
    
    # Summary statistics
    total_shares=$(wc -l < /tmp/fileshare_table.txt)
    backed_up_shares=$(grep -c "|Yes|" /tmp/fileshare_table.txt)
    not_backed_up_shares=$(grep -c "|No|" /tmp/fileshare_table.txt)
    
    echo "=========================================="
    echo "SUMMARY STATISTICS"
    echo "=========================================="
    echo "Total File Shares: $total_shares"
    echo "  ✓ With Azure Backup: $backed_up_shares"
    echo "  ✗ WITHOUT Backup: $not_backed_up_shares"
    
    if [ "$not_backed_up_shares" -gt 0 ]; then
        echo ""
        echo "⚠ WARNING: $not_backed_up_shares file share(s) have NO backup configured!"
        echo "Consider enabling Azure Backup for these shares."
    fi
    
    echo ""
    
    # Calculate total used capacity
    total_backed_up_capacity=$(awk -F'|' '$7 == "Yes" && $6 != "N/A" && $6 != "0" {sum += $6} END {printf "%.2f", sum+0}' /tmp/fileshare_table.txt)
    total_not_backed_up_capacity=$(awk -F'|' '$7 == "No" && $6 != "N/A" && $6 != "0" {sum += $6} END {printf "%.2f", sum+0}' /tmp/fileshare_table.txt)
    total_capacity=$(awk -F'|' '$6 != "N/A" && $6 != "0" {sum += $6} END {printf "%.2f", sum+0}' /tmp/fileshare_table.txt)
    
    echo "Used Capacity:"
    if [ "$total_capacity" == "0.00" ]; then
        echo "  Note: Usage data not available for these file shares"
        echo "  (Azure Storage may not report usage immediately after creation)"
    else
        echo "  Total: ${total_capacity} GB"
        echo "  ✓ Protected by Backup: ${total_backed_up_capacity} GB"
        echo "  ✗ NOT Protected: ${total_not_backed_up_capacity} GB"
    fi
    
else
    echo "No file shares found in this subscription."
fi

# Cleanup
rm -f /tmp/fileshare_table.txt
rm -f "$protected_shares_list"

echo ""
echo "=========================================="
echo "Analysis Complete"
echo "=========================================="

# List CSV file
CSV_FILES=$(ls /tmp/azure_fileshare_backup_*.csv 2>/dev/null)
if [ ! -z "$CSV_FILES" ]; then
    CSV_FILE=$(echo "$CSV_FILES" | head -n 1)
    echo ""
    echo "CSV Export: $(basename $CSV_FILE)"
    echo ""
    echo "To download the CSV file:"
    echo "  download /tmp/$(basename $CSV_FILE)"
    echo ""
fi

