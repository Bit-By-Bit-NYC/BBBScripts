<#
.SYNOPSIS
    This script audits all virtual machines in the current Azure subscription to identify the publisher and SKU of the image used to create them.

.DESCRIPTION
    It retrieves a list of all VMs, then for each VM, it fetches detailed information to find the image reference publisher and SKU.
    This is useful for ensuring that all VMs are built from approved or expected image sources.

.OUTPUTS
    Outputs custom PowerShell objects containing the VM Name, Resource Group, Image Publisher, and Image SKU.
    If image details cannot be determined (e.g., for custom images), they will be noted as 'Custom Image' or 'Unknown'.
#>

# Ensures you are connected to your Azure account
Connect-AzAccount

Write-Host "Starting audit of VM image publishers and SKUs across all resource groups..." -ForegroundColor Yellow

# Get all Virtual Machines in the current subscription
$allVMs = Get-AzVM

# Create an array to hold the results
$results = @()

# Loop through each VM
foreach ($vm in $allVMs) {
    # Initialize properties to default values
    $publisher = "Unknown / Custom Image"
    $sku = "Unknown / Custom Image"

    # Check if the VM was created from a marketplace image
    if ($null -ne $vm.StorageProfile.ImageReference) {
        $publisher = $vm.StorageProfile.ImageReference.Publisher
        $sku = $vm.StorageProfile.ImageReference.Sku
    }
    # If it's a custom image from a gallery, these fields will be null.
    # The default values assigned above will be used in that case.

    # Add the details to our results array
    $results += [PSCustomObject]@{
        VMName         = $vm.Name
        ResourceGroup  = $vm.ResourceGroupName
        ImagePublisher = $publisher
        ImageSku       = $sku
    }
}

# Display the results in a table
Write-Host "Audit Complete! ✅" -ForegroundColor Green
$results | Format-Table -AutoSize

# Optional: Export the results to a CSV file for further analysis
# $results | Export-Csv -Path "C:\temp\VM_Image_Audit.csv" -NoTypeInformation
# Write-Host "Results also exported to C:\temp\VM_Image_Audit.csv" -ForegroundColor Cyan