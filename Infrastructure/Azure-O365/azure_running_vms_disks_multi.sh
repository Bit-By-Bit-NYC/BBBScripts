#!/bin/bash

# Script to list and summarize VHDs attached to running Azure VMs
# Supports single subscription or all subscriptions
# Usage: Paste this into Azure Cloud Shell (Bash)

# Clean up old CSV files from previous runs
rm -f /tmp/azure_vm_disks_*.csv 2>/dev/null

echo "=========================================="
echo "Azure Running VMs - Disk Analysis"
echo "=========================================="
echo ""

# Function to calculate monthly disk cost in USD (approximate)
calculate_disk_cost() {
    local size_gb=$1
    local sku=$2
    local cost=0
    
    case $sku in
        "Premium_LRS"|"PremiumV2_LRS")
            # Premium SSD pricing tiers (US East 2025 pricing)
            if [ $size_gb -le 4 ]; then cost=0.60
            elif [ $size_gb -le 8 ]; then cost=1.20
            elif [ $size_gb -le 16 ]; then cost=2.40
            elif [ $size_gb -le 32 ]; then cost=4.81
            elif [ $size_gb -le 64 ]; then cost=9.62
            elif [ $size_gb -le 128 ]; then cost=19.71
            elif [ $size_gb -le 256 ]; then cost=38.50
            elif [ $size_gb -le 512 ]; then cost=76.99
            elif [ $size_gb -le 1024 ]; then cost=135.17
            elif [ $size_gb -le 2048 ]; then cost=270.34
            elif [ $size_gb -le 4096 ]; then cost=540.67
            elif [ $size_gb -le 8192 ]; then cost=1081.34
            elif [ $size_gb -le 16384 ]; then cost=2162.69
            else cost=4325.38
            fi
            ;;
        "StandardSSD_LRS")
            # Standard SSD pricing tiers (US East 2025 pricing - corrected)
            if [ $size_gb -le 4 ]; then cost=0.75
            elif [ $size_gb -le 8 ]; then cost=1.54
            elif [ $size_gb -le 16 ]; then cost=3.01
            elif [ $size_gb -le 32 ]; then cost=6.00
            elif [ $size_gb -le 64 ]; then cost=12.00
            elif [ $size_gb -le 128 ]; then cost=9.60
            elif [ $size_gb -le 256 ]; then cost=19.00
            elif [ $size_gb -le 512 ]; then cost=38.00
            elif [ $size_gb -le 1024 ]; then cost=96.00
            elif [ $size_gb -le 2048 ]; then cost=192.00
            elif [ $size_gb -le 4096 ]; then cost=384.00
            elif [ $size_gb -le 8192 ]; then cost=768.00
            elif [ $size_gb -le 16384 ]; then cost=1536.00
            else cost=3072.00
            fi
            ;;
        "Standard_LRS")
            # Standard HDD pricing (~$0.04/GB/month)
            cost=$(awk "BEGIN {printf \"%.2f\", $size_gb * 0.04}")
            ;;
        "UltraSSD_LRS")
            # Ultra SSD pricing (capacity + IOPS + throughput, approximate)
            cost=$(awk "BEGIN {printf \"%.2f\", $size_gb * 0.14746}")
            ;;
        *)
            # Default/unknown
            cost=0
            ;;
    esac
    
    echo $cost
}

# Function to process a single subscription
process_subscription() {
    local sub_id=$1
    local sub_name=$2
    local show_details=${3:-true}
    
    if [ "$show_details" == "true" ]; then
        echo ""
        echo "=========================================="
        echo "Processing: $sub_name"
        echo "=========================================="
    fi
    
    # Set the subscription
    az account set --subscription "$sub_id" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Failed to set subscription $sub_name"
        return 1
    fi
    
    # Get all running VMs
    if [ "$show_details" == "true" ]; then
        echo "Finding all running VMs in subscription..."
    fi
    
    running_vms=$(az vm list -d --query "[?powerState=='VM running'].{Name:name, ResourceGroup:resourceGroup, Location:location, ID:id}" -o json)
    vm_count=$(echo "$running_vms" | jq '. | length')
    
    if [ "$show_details" == "true" ]; then
        echo "Found $vm_count running VM(s)"
        echo ""
    fi
    
    if [ "$vm_count" -eq 0 ]; then
        if [ "$show_details" == "true" ]; then
            echo "No running VMs found in this subscription."
        fi
        return 0
    fi
    
    if [ "$show_details" == "true" ]; then
        echo "=========================================="
        echo "DETAILED VM DISK INFORMATION"
        echo "=========================================="
        echo ""
    fi
    
    # Loop through each running VM
    echo "$running_vms" | jq -c '.[]' | while read -r vm; do
        vm_name=$(echo "$vm" | jq -r '.Name')
        rg=$(echo "$vm" | jq -r '.ResourceGroup')
        location=$(echo "$vm" | jq -r '.Location')
        
        if [ "$show_details" == "true" ]; then
            echo "──────────────────────────────────────"
            echo "VM: $vm_name"
            echo "Resource Group: $rg"
            echo "Location: $location"
            echo "──────────────────────────────────────"
        fi
        
        # Get VM details including disk info
        vm_details=$(az vm show -n "$vm_name" -g "$rg")
        
        # OS Disk
        if [ "$show_details" == "true" ]; then
            echo ""
            echo "  OS DISK:"
        fi
        
        os_disk_name=$(echo "$vm_details" | jq -r '.storageProfile.osDisk.name')
        os_disk_id=$(echo "$vm_details" | jq -r '.storageProfile.osDisk.managedDisk.id')
        
        if [ ! -z "$os_disk_id" ] && [ "$os_disk_id" != "null" ]; then
            os_disk_details=$(az disk show --ids "$os_disk_id" 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                # Get disk size in GB
                os_disk_size=$(echo "$os_disk_details" | jq -r '.diskSizeGb')
                
                # If diskSizeGb is null, convert from bytes
                if [ -z "$os_disk_size" ] || [ "$os_disk_size" == "null" ]; then
                    disk_size_bytes=$(echo "$os_disk_details" | jq -r '.diskSizeBytes // empty')
                    if [ ! -z "$disk_size_bytes" ] && [ "$disk_size_bytes" != "null" ]; then
                        os_disk_size=$((disk_size_bytes / 1073741824))
                    fi
                fi
                
                # If still empty, try getting from VM details
                if [ -z "$os_disk_size" ] || [ "$os_disk_size" == "null" ]; then
                    os_disk_size=$(echo "$vm_details" | jq -r '.storageProfile.osDisk.diskSizeGb // empty')
                fi
                
                os_disk_sku=$(echo "$os_disk_details" | jq -r '.sku.name // empty')
                os_disk_state=$(echo "$os_disk_details" | jq -r '.diskState // empty')
                
                # Calculate cost
                if [ ! -z "$os_disk_size" ] && [ "$os_disk_size" != "null" ] && [ ! -z "$os_disk_sku" ]; then
                    os_disk_cost=$(calculate_disk_cost $os_disk_size $os_disk_sku)
                else
                    os_disk_cost="0"
                fi
                
                if [ "$show_details" == "true" ]; then
                    echo "    Name: $os_disk_name"
                    echo "    Size: ${os_disk_size:-Unknown} GB"
                    echo "    SKU: ${os_disk_sku:-Unknown}"
                    echo "    State: ${os_disk_state:-Unknown}"
                    echo "    Est. Monthly Cost: \$${os_disk_cost}"
                fi
            fi
        fi
        
        # Data Disks
        data_disk_count=$(echo "$vm_details" | jq '.storageProfile.dataDisks | length')
        
        if [ "$show_details" == "true" ]; then
            echo ""
            echo "  DATA DISKS: ($data_disk_count)"
        fi
        
        if [ "$data_disk_count" -gt 0 ]; then
            echo "$vm_details" | jq -c '.storageProfile.dataDisks[]' | while read -r disk; do
                disk_name=$(echo "$disk" | jq -r '.name')
                disk_lun=$(echo "$disk" | jq -r '.lun')
                disk_id=$(echo "$disk" | jq -r '.managedDisk.id')
                
                disk_details=$(az disk show --ids "$disk_id" 2>/dev/null)
                
                if [ $? -eq 0 ]; then
                    # Get disk size in GB
                    disk_size=$(echo "$disk_details" | jq -r '.diskSizeGb')
                    
                    # If diskSizeGb is null, convert from bytes
                    if [ -z "$disk_size" ] || [ "$disk_size" == "null" ]; then
                        disk_size_bytes=$(echo "$disk_details" | jq -r '.diskSizeBytes // empty')
                        if [ ! -z "$disk_size_bytes" ] && [ "$disk_size_bytes" != "null" ]; then
                            disk_size=$((disk_size_bytes / 1073741824))
                        fi
                    fi
                    
                    # If still empty, try getting from disk info
                    if [ -z "$disk_size" ] || [ "$disk_size" == "null" ]; then
                        disk_size=$(echo "$disk" | jq -r '.diskSizeGb // empty')
                    fi
                    
                    disk_sku=$(echo "$disk_details" | jq -r '.sku.name // empty')
                    disk_state=$(echo "$disk_details" | jq -r '.diskState // empty')
                    
                    # Calculate cost
                    if [ ! -z "$disk_size" ] && [ "$disk_size" != "null" ] && [ ! -z "$disk_sku" ]; then
                        disk_cost=$(calculate_disk_cost $disk_size $disk_sku)
                    else
                        disk_cost="0"
                    fi
                    
                    if [ "$show_details" == "true" ]; then
                        echo "    [$disk_lun] Name: $disk_name"
                        echo "        Size: ${disk_size:-Unknown} GB"
                        echo "        SKU: ${disk_sku:-Unknown}"
                        echo "        State: ${disk_state:-Unknown}"
                        echo "        Est. Monthly Cost: \$${disk_cost}"
                        echo ""
                    fi
                fi
            done
        else
            if [ "$show_details" == "true" ]; then
                echo "    No data disks attached"
            fi
        fi
        
        if [ "$show_details" == "true" ]; then
            echo ""
        fi
    done
    
    # Generate summary table and CSV
    generate_summary "$sub_id" "$sub_name" "$vm_count" "$show_details"
}

# Function to generate summary table and CSV
generate_summary() {
    local sub_id=$1
    local sub_name=$2
    local vm_count=$3
    local show_details=${4:-true}
    
    # Create a detailed table
    local table_file="/tmp/disk_table_${sub_id}.txt"
    > "$table_file"
    
    # Get all running VMs for this subscription
    running_vms=$(az vm list -d --query "[?powerState=='VM running'].{Name:name, ResourceGroup:resourceGroup}" -o json)
    
    echo "$running_vms" | jq -c '.[]' | while read -r vm; do
        vm_name=$(echo "$vm" | jq -r '.Name')
        rg=$(echo "$vm" | jq -r '.ResourceGroup')
        
        # Get VM details
        vm_info=$(az vm show -n "$vm_name" -g "$rg" 2>/dev/null)
        
        # Process OS disk
        os_disk_id=$(echo "$vm_info" | jq -r '.storageProfile.osDisk.managedDisk.id // empty')
        if [ ! -z "$os_disk_id" ] && [ "$os_disk_id" != "null" ]; then
            disk_info=$(az disk show --ids "$os_disk_id" 2>/dev/null)
            if [ $? -eq 0 ]; then
                disk_name=$(echo "$disk_info" | jq -r '.name')
                size_gb=$(echo "$disk_info" | jq -r '.diskSizeGb')
                
                # If diskSizeGb is null, convert from bytes
                if [ -z "$size_gb" ] || [ "$size_gb" == "null" ]; then
                    size_bytes=$(echo "$disk_info" | jq -r '.diskSizeBytes // empty')
                    if [ ! -z "$size_bytes" ] && [ "$size_bytes" != "null" ]; then
                        size_gb=$((size_bytes / 1073741824))
                    fi
                fi
                
                sku=$(echo "$disk_info" | jq -r '.sku.name // "Unknown"')
                
                # Calculate cost
                if [ ! -z "$size_gb" ] && [ "$size_gb" != "null" ] && [ ! -z "$sku" ] && [ "$sku" != "Unknown" ]; then
                    cost=$(calculate_disk_cost $size_gb $sku)
                else
                    cost="0"
                fi
                
                if [ ! -z "$size_gb" ] && [ "$size_gb" != "null" ]; then
                    echo "$vm_name|$disk_name|OS|$size_gb|$sku|$cost" >> "$table_file"
                fi
            fi
        fi
        
        # Process data disks
        echo "$vm_info" | jq -r '.storageProfile.dataDisks[]?.managedDisk.id // empty' | while read -r disk_id; do
            if [ ! -z "$disk_id" ] && [ "$disk_id" != "null" ]; then
                disk_info=$(az disk show --ids "$disk_id" 2>/dev/null)
                if [ $? -eq 0 ]; then
                    disk_name=$(echo "$disk_info" | jq -r '.name')
                    size_gb=$(echo "$disk_info" | jq -r '.diskSizeGb')
                    
                    # If diskSizeGb is null, convert from bytes
                    if [ -z "$size_gb" ] || [ "$size_gb" == "null" ]; then
                        size_bytes=$(echo "$disk_info" | jq -r '.diskSizeBytes // empty')
                        if [ ! -z "$size_bytes" ] && [ "$size_bytes" != "null" ]; then
                            size_gb=$((size_bytes / 1073741824))
                        fi
                    fi
                    
                    sku=$(echo "$disk_info" | jq -r '.sku.name // "Unknown"')
                    
                    # Calculate cost
                    if [ ! -z "$size_gb" ] && [ "$size_gb" != "null" ] && [ ! -z "$sku" ] && [ "$sku" != "Unknown" ]; then
                        cost=$(calculate_disk_cost $size_gb $sku)
                    else
                        cost="0"
                    fi
                    
                    if [ ! -z "$size_gb" ] && [ "$size_gb" != "null" ]; then
                        echo "$vm_name|$disk_name|Data|$size_gb|$sku|$cost" >> "$table_file"
                    fi
                fi
            fi
        done
    done
    
    # Create CSV file
    if [ -f "$table_file" ] && [ -s "$table_file" ]; then
        # Get tenant name
        TENANT_NAME=$(az account show --query 'tenantDisplayName' -o tsv 2>/dev/null | tr ' ' '_' | tr -cd '[:alnum:]_-')
        
        # Fallback to tenant ID if name not available
        if [ -z "$TENANT_NAME" ]; then
            TENANT_NAME=$(az account show --query 'tenantId' -o tsv 2>/dev/null)
        fi
        
        # Clean subscription name for filename
        CLEAN_SUB_NAME=$(echo "$sub_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
        
        # Create filename
        CSV_FILE="azure_vm_disks_${TENANT_NAME}_${CLEAN_SUB_NAME}_$(date +%Y%m%d_%H%M%S).csv"
        
        # Write CSV header
        echo "Subscription Name,VM Name,Disk Name,Type,Size (GB),SKU,Monthly Cost (USD),Total VMs in Subscription" > "/tmp/$CSV_FILE"
        
        # Write CSV data
        while IFS='|' read -r vm_name disk_name disk_type size_gb sku cost; do
            echo "\"$sub_name\",\"$vm_name\",\"$disk_name\",\"$disk_type\",$size_gb,\"$sku\",$cost,$vm_count" >> "/tmp/$CSV_FILE"
        done < "$table_file"
        
        if [ "$show_details" == "true" ]; then
            echo "CSV file created: $CSV_FILE"
            echo ""
        fi
    fi
    
    # Display the table
    if [ "$show_details" == "true" ]; then
        if [ -f "$table_file" ] && [ -s "$table_file" ]; then
            echo "=========================================="
            echo "SUMMARY TABLE - ALL DISKS"
            echo "=========================================="
            printf "%-30s %-60s %-8s %-10s %-20s %-15s\n" "VM NAME" "DISK NAME" "TYPE" "SIZE (GB)" "SKU" "MONTHLY COST"
            printf "%-30s %-60s %-8s %-10s %-20s %-15s\n" "$(printf '%0.s─' {1..30})" "$(printf '%0.s─' {1..60})" "$(printf '%0.s─' {1..8})" "$(printf '%0.s─' {1..10})" "$(printf '%0.s─' {1..20})" "$(printf '%0.s─' {1..15})"
            
            while IFS='|' read -r vm_name disk_name disk_type size_gb sku cost; do
                printf "%-30s %-60s %-8s %-10s %-20s \$%-14s\n" "$vm_name" "$disk_name" "$disk_type" "$size_gb" "$sku" "$cost"
            done < "$table_file"
            
            echo ""
            echo "Note: Total VMs in Subscription: $vm_count"
        fi
        
        echo ""
        echo "=========================================="
        echo "SUMMARY STATISTICS"
        echo "=========================================="
        
        # Calculate summary statistics
        if [ -f "$table_file" ] && [ -s "$table_file" ]; then
            awk -F'|' '
            BEGIN {
                total_disks = 0
                total_size = 0
                total_cost = 0
            }
            {
                if ($4 != "" && $4 != "null") {
                    total_disks++
                    total_size += $4
                    if ($6 != "" && $6 != "null") {
                        total_cost += $6
                    }
                    if ($5 != "" && $5 != "null") {
                        sku_count[$5]++
                    }
                }
            }
            END {
                print "Total Running VMs: " vm_count
                print "Total Disks Attached: " total_disks
                print "Total Storage: " total_size " GB"
                printf "Total Estimated Monthly Cost: $%.2f USD\n", total_cost
                if (total_disks > 0) {
                    printf "Average Cost Per Disk: $%.2f USD/month\n", total_cost / total_disks
                }
                print ""
                print "Disk SKU Breakdown:"
                for (sku in sku_count) {
                    print "  " sku ": " sku_count[sku] " disk(s)"
                }
                print ""
                print "Note: Costs are estimates based on US East pricing and may vary by region."
                print "      Actual costs may differ based on reserved instances, discounts, and usage."
            }
            ' vm_count="$vm_count" "$table_file"
        else
            echo "Total Running VMs: $vm_count"
            echo "Total Disks Attached: 0"
            echo "Total Storage: 0 GB"
            echo "Total Estimated Monthly Cost: $0.00 USD"
            echo ""
            echo "Disk SKU Breakdown:"
            echo "  None found"
        fi
    fi
    
    # Cleanup table file
    rm -f "$table_file"
}

# Main script logic
echo "Available subscriptions:"
echo ""
az account list --query "[].{Name:name, ID:id}" -o table

echo ""
echo "Current subscription:"
az account show --query "{Name:name, ID:id}" -o table

echo ""
echo "Options:"
echo "  1. Analyze single subscription (current or selected)"
echo "  2. Analyze ALL subscriptions (creates separate CSV for each)"
echo ""
read -p "Enter your choice (1 or 2): " choice

if [ "$choice" == "2" ]; then
    # Multi-subscription mode
    echo ""
    echo "Multi-subscription mode selected."
    echo "This will process all subscriptions you have access to."
    echo ""
    read -p "Continue? (y/n): " confirm
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    
    # Get all subscription IDs
    ALL_SUBS=$(az account list --query "[].{id:id, name:name}" -o json)
    SUB_COUNT=$(echo "$ALL_SUBS" | jq '. | length')
    
    echo ""
    echo "Processing $SUB_COUNT subscriptions..."
    echo ""
    
    # Process each subscription
    CURRENT_SUB=1
    echo "$ALL_SUBS" | jq -c '.[]' | while read -r sub; do
        sub_id=$(echo "$sub" | jq -r '.id')
        sub_name=$(echo "$sub" | jq -r '.name')
        
        echo ""
        echo "=========================================="
        echo "[$CURRENT_SUB/$SUB_COUNT] Subscription: $sub_name"
        echo "=========================================="
        
        process_subscription "$sub_id" "$sub_name" "false"
        
        CURRENT_SUB=$((CURRENT_SUB + 1))
        
        echo "Completed: $sub_name"
        echo ""
    done
    
    echo ""
    echo "=========================================="
    echo "Multi-Subscription Analysis Complete"
    echo "=========================================="
    echo ""
    echo "CSV files created in /tmp/"
    echo "To download all CSV files:"
    echo "  ls /tmp/azure_vm_disks_*.csv"
    
else
    # Single subscription mode
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
    
    # Get current subscription details
    CURRENT_SUB_ID=$(az account show --query 'id' -o tsv)
    CURRENT_SUB_NAME=$(az account show --query 'name' -o tsv)
    
    # Process single subscription
    process_subscription "$CURRENT_SUB_ID" "$CURRENT_SUB_NAME" "true"
fi

echo ""
echo "=========================================="
echo "Analysis Complete"
echo "=========================================="

# List all CSV files created
CSV_FILES=$(ls /tmp/azure_vm_disks_*.csv 2>/dev/null)
if [ ! -z "$CSV_FILES" ]; then
    echo ""
    echo "CSV file(s) created:"
    ls -1 /tmp/azure_vm_disks_*.csv | xargs -n 1 basename
    echo ""
    echo "To download a CSV file:"
    echo "  download /tmp/azure_vm_disks_FILENAME.csv"
    echo ""
fi
