#!/bin/bash

# Script to list Azure File Shares and their backup status across multiple subscriptions
# Checks for Azure Backup via Recovery Services Vault
# Usage: Paste this into Azure Cloud Shell (Bash)

# Clean up old CSV files from previous runs
rm -f /tmp/azure_fileshare_backup_*.csv 2>/dev/null

echo "=========================================="
echo "Azure File Shares - Backup Analysis"
echo "Multi-Subscription Mode"
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
echo "Select mode:"
echo "1) Single subscription"
echo "2) All accessible subscriptions"
echo ""
read -p "Enter choice (1 or 2): " mode_choice

# Get tenant name for CSV filename (use first subscription's tenant)
TENANT_NAME=$(az account show --query 'tenantDisplayName' -o tsv 2>/dev/null | tr ' ' '_' | tr -cd '[:alnum:]_-')
if [ -z "$TENANT_NAME" ]; then
    TENANT_NAME=$(az account show --query 'tenantId' -o tsv 2>/dev/null)
fi

# Create consolidated CSV file
CSV_FILE="azure_fileshare_backup_${TENANT_NAME}_AllSubscriptions_$(date +%Y%m%d_%H%M%S).csv"

# Write CSV header
echo "Tenant Name,Subscription Name,Subscription ID,Storage Account,Resource Group,Location,File Share,Quota (GB),Used Capacity (GB),Backup Enabled,Protection State,Last Backup,Recovery Vault" > "/tmp/$CSV_FILE"

# Determine subscriptions to process
if [ "$mode_choice" == "2" ]; then
    # Get all subscriptions
    subscriptions=$(az account list --query "[].{Name:name, ID:id}" -o json)
    sub_count=$(echo "$subscriptions" | jq '. | length')
    echo ""
    echo "Processing $sub_count subscription(s)..."
    echo ""
else
    # Single subscription mode
    echo ""
    read -p "Enter subscription ID or name (or press Enter to use current): " sub_input
    
    if [ ! -z "$sub_input" ]; then
        subscriptions=$(az account list --query "[?name=='$sub_input' || id=='$sub_input'].{Name:name, ID:id}" -o json)
    else
        subscriptions=$(az account show --query "{Name:name, ID:id}" -o json | jq '[.]')
    fi
    sub_count=1
fi

# Global counters for final summary
GLOBAL_TOTAL_SHARES=0
GLOBAL_BACKED_UP_SHARES=0
GLOBAL_NOT_BACKED_UP_SHARES=0
GLOBAL_TOTAL_CAPACITY=0
GLOBAL_BACKED_UP_CAPACITY=0
GLOBAL_NOT_BACKED_UP_CAPACITY=0

# Process each subscription
current_sub_num=0
echo "$subscriptions" | jq -c '.[]' | while read -r subscription; do
    current_sub_num=$((current_sub_num + 1))
    
    SUB_NAME=$(echo "$subscription" | jq -r '.Name')
    SUB_ID=$(echo "$subscription" | jq -r '.ID')
    
    echo "=========================================="
    echo "[$current_sub_num/$sub_count] Processing Subscription"
    echo "=========================================="
    echo "Name: $SUB_NAME"
    echo "ID: $SUB_ID"
    echo "=========================================="
    echo ""
    
    # Set the subscription
    az account set --subscription "$SUB_ID" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "⚠ Warning: Could not set subscription $SUB_NAME. Skipping..."
        echo ""
        continue
    fi
    
    # Get tenant name for this subscription
    SUB_TENANT_NAME=$(az account show --query 'tenantDisplayName' -o tsv 2>/dev/null | tr ' ' '_' | tr -cd '[:alnum:]_-')
    if [ -z "$SUB_TENANT_NAME" ]; then
        SUB_TENANT_NAME=$(az account show --query 'tenantId' -o tsv 2>/dev/null)
    fi
    
    echo "Step 1: Finding all storage accounts with file shares..."
    echo ""
    
    # Get all storage accounts
    storage_accounts=$(az storage account list --query "[].{Name:name, ResourceGroup:resourceGroup, Location:location}" -o json 2>/dev/null)
    sa_count=$(echo "$storage_accounts" | jq '. | length' 2>/dev/null)
    
    if [ -z "$sa_count" ] || [ "$sa_count" == "0" ]; then
        echo "No storage accounts found in this subscription."
        echo ""
        continue
    fi
    
    echo "Found $sa_count storage account(s) to check"
    echo ""
    
    echo "Step 2: Getting all protected file shares from Recovery Services Vaults..."
    echo ""
    
    # Get all Recovery Services Vaults and their protected items
    protected_shares_list="/tmp/protected_shares_${SUB_ID}.txt"
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
    > /tmp/fileshare_table_${SUB_ID}.txt
    
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
                    # Try to get file share capacity via metrics (last 1 hour)
                    capacity_bytes=$(az monitor metrics list \
                        --resource "/subscriptions/$SUB_ID/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$sa_name/fileServices/default" \
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
                fi
                
                # Ensure we have numeric values for the table (use 0 if empty)
                if [ -z "$quota_gb" ] || [ "$quota_gb" == "null" ]; then
                    quota_gb="0"
                fi
                if [ -z "$usage_gb" ] || [ "$usage_gb" == "null" ]; then
                    usage_gb="0"
                fi
                
                # Write to subscription-specific table
                echo "$sa_name|$rg|$location|$share_name|$quota_gb|$usage_gb|$backup_status|$protection_state|$last_backup|$vault_name" >> /tmp/fileshare_table_${SUB_ID}.txt
                
                # Write to consolidated CSV
                echo "\"$SUB_TENANT_NAME\",\"$SUB_NAME\",\"$SUB_ID\",\"$sa_name\",\"$rg\",\"$location\",\"$share_name\",$quota_gb,$usage_gb,\"$backup_status\",\"$protection_state\",\"$last_backup\",\"$vault_name\"" >> "/tmp/$CSV_FILE"
                
                echo ""
            done
        fi
    done
    
    echo ""
    echo "──────────────────────────────────────"
    echo "Subscription Summary: $SUB_NAME"
    echo "──────────────────────────────────────"
    
    # Display subscription summary
    if [ -f /tmp/fileshare_table_${SUB_ID}.txt ] && [ -s /tmp/fileshare_table_${SUB_ID}.txt ]; then
        total_shares=$(wc -l < /tmp/fileshare_table_${SUB_ID}.txt)
        backed_up_shares=$(grep -c "|Yes|" /tmp/fileshare_table_${SUB_ID}.txt)
        not_backed_up_shares=$(grep -c "|No|" /tmp/fileshare_table_${SUB_ID}.txt)
        
        echo "Total File Shares: $total_shares"
        echo "  ✓ With Azure Backup: $backed_up_shares"
        echo "  ✗ WITHOUT Backup: $not_backed_up_shares"
        
        if [ "$not_backed_up_shares" -gt 0 ]; then
            echo ""
            echo "⚠ WARNING: $not_backed_up_shares file share(s) have NO backup configured!"
        fi
        
        # Calculate capacity for this subscription
        sub_backed_up_capacity=$(awk -F'|' '$7 == "Yes" && $6 != "N/A" && $6 != "0" {sum += $6} END {printf "%.2f", sum+0}' /tmp/fileshare_table_${SUB_ID}.txt)
        sub_not_backed_up_capacity=$(awk -F'|' '$7 == "No" && $6 != "N/A" && $6 != "0" {sum += $6} END {printf "%.2f", sum+0}' /tmp/fileshare_table_${SUB_ID}.txt)
        sub_total_capacity=$(awk -F'|' '$6 != "N/A" && $6 != "0" {sum += $6} END {printf "%.2f", sum+0}' /tmp/fileshare_table_${SUB_ID}.txt)
        
        echo ""
        echo "Used Capacity:"
        if [ "$sub_total_capacity" == "0.00" ]; then
            echo "  Note: Usage data not available"
        else
            echo "  Total: ${sub_total_capacity} GB"
            echo "  ✓ Protected: ${sub_backed_up_capacity} GB"
            echo "  ✗ NOT Protected: ${sub_not_backed_up_capacity} GB"
        fi
    else
        echo "No file shares found in this subscription."
    fi
    
    # Cleanup subscription-specific files
    rm -f "$protected_shares_list"
    rm -f /tmp/fileshare_table_${SUB_ID}.txt
    
    echo ""
done

echo ""
echo "=========================================="
echo "CONSOLIDATED SUMMARY - ALL SUBSCRIPTIONS"
echo "=========================================="
echo ""

# Count total lines in CSV (excluding header)
total_lines=$(wc -l < "/tmp/$CSV_FILE")
total_shares=$((total_lines - 1))

if [ "$total_shares" -gt 0 ]; then
    # Count backed up vs not backed up from CSV
    backed_up_count=$(grep -c ",\"Yes\"," "/tmp/$CSV_FILE")
    not_backed_up_count=$(grep -c ",\"No\"," "/tmp/$CSV_FILE")
    
    echo "Total File Shares Across All Subscriptions: $total_shares"
    echo "  ✓ With Azure Backup: $backed_up_count"
    echo "  ✗ WITHOUT Backup: $not_backed_up_count"
    
    if [ "$not_backed_up_count" -gt 0 ]; then
        echo ""
        echo "⚠ WARNING: $not_backed_up_count file share(s) have NO backup configured!"
        echo "Consider enabling Azure Backup for these shares."
    fi
    
    # Calculate total capacity from CSV (column 9 is Used Capacity)
    total_capacity=$(awk -F',' 'NR>1 && $9 != "0" {sum += $9} END {printf "%.2f", sum+0}' "/tmp/$CSV_FILE")
    backed_up_capacity=$(awk -F',' 'NR>1 && $10 == "\"Yes\"" && $9 != "0" {sum += $9} END {printf "%.2f", sum+0}' "/tmp/$CSV_FILE")
    not_backed_up_capacity=$(awk -F',' 'NR>1 && $10 == "\"No\"" && $9 != "0" {sum += $9} END {printf "%.2f", sum+0}' "/tmp/$CSV_FILE")
    
    echo ""
    echo "Total Used Capacity Across All Subscriptions:"
    if [ "$total_capacity" == "0.00" ]; then
        echo "  Note: Usage data not available for file shares"
    else
        echo "  Total: ${total_capacity} GB"
        echo "  ✓ Protected by Backup: ${backed_up_capacity} GB"
        echo "  ✗ NOT Protected: ${not_backed_up_capacity} GB"
    fi
    
    echo ""
    echo "CSV Export: $CSV_FILE"
    echo ""
    echo "The CSV contains all file shares from all subscriptions with:"
    echo "  - Tenant Name"
    echo "  - Subscription Name & ID"
    echo "  - Storage Account details"
    echo "  - File Share details"
    echo "  - Backup status"
    echo "  - Used capacity"
else
    echo "No file shares found in any subscription."
fi

echo ""
echo "=========================================="
echo "Analysis Complete"
echo "=========================================="
echo ""
echo "To download the consolidated CSV file:"
echo "  download /tmp/$CSV_FILE"
echo ""
