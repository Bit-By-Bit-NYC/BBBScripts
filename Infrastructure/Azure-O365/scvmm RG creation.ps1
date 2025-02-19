#run "connect-AzAccount" before running this script
#This script creates a resource group in the azure tenant with the name scheme 'rg-arc-scvmm-<client>', and creates equivalent permissions to the group defined in $ExistingResourceGroupName

# Define the list of client codes
$ClientCodes = @(
    "<client code>"
    "<client code 2>"
    # Add more client codes as needed
)

# Define the existing resource group to copy permissions from
$ExistingResourceGroupName = "rg-arc-scvmm-<client>" 

# Get the existing resource group's ID
try {
    $ExistingResourceGroup = Get-AzResourceGroup -Name $ExistingResourceGroupName
    $ExistingResourceGroupId = $ExistingResourceGroup.ResourceId
}
catch {
    Write-Error "Error getting existing resource group '$ExistingResourceGroupName': $_"
    return  # Exit the script if the existing RG is not found
}


foreach ($ClientCode in $ClientCodes) {
    # Construct the new resource group name
    $NewResourceGroupName = "rg-arc-scvmm-$ClientCode"

    Write-Host "Creating resource group: $NewResourceGroupName"

    try {
        # Create the new resource group
        $NewResourceGroup = New-AzResourceGroup -Name $NewResourceGroupName -Location "EastUS" # Replace with your desired location

        # Copy permissions from the existing resource group
        # This involves getting the role assignments from the existing RG and applying them to the new RG.

        $RoleAssignments = Get-AzRoleAssignment -Scope $ExistingResourceGroupId

        foreach ($RoleAssignment in $RoleAssignments) {
            # Check if it is a role definition or role assignment. Some role definitions cannot be assigned.
            if ($RoleAssignment.ObjectType -eq "RoleDefinition") {
                Write-Host "Skipping $RoleAssignment.DisplayName as it is a Role Definition and cannot be assigned."
                continue
            }

            try {
                # Create the role assignment for the new resource group.
                New-AzRoleAssignment -ObjectId $RoleAssignment.ObjectId -RoleDefinitionId $RoleAssignment.RoleDefinitionId -Scope $NewResourceGroup.ResourceId
                Write-Host "Assigned role '$RoleAssignment.DisplayName' to resource group '$NewResourceGroupName'"

            }
            catch {
                Write-Warning "Failed to assign role '$RoleAssignment.DisplayName' to resource group '$NewResourceGroupName'. Error: $_"
                # Consider adding more robust error handling here, like logging or retry logic.
            }
        }

    }
    catch {
        Write-Error "Error creating resource group '$NewResourceGroupName': $_"
    }
}

Write-Host "Script completed."