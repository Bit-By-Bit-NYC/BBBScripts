# Variables
SUB="98a534ec-4bbd-461f-b87d-55d836a38a57"
RG="rg-asr-scan"
LOC="eastus2"
APP="func-asr-scan"
STOR="st${RANDOM}asrscan"

az group create -n $RG -l $LOC
az storage account create -g $RG -n $STOR -l $LOC --sku Standard_LRS --kind StorageV2

# Create Function App (Linux, .NET 8) with System-Assigned MI
az functionapp create -g $RG -n $APP \
  --consumption-plan-location $LOC \
  --storage-account $STOR \
  --assign-identity \
  --runtime dotnet-isolated --functions-version 4

# Grant RBAC to MI
PRINCIPAL_ID=$(az functionapp identity show -g $RG -n $APP --query principalId -o tsv)

# Reader on subscription (for vault discovery)
az role assignment create --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Reader" --scope /subscriptions/$SUB

# Site Recovery Reader on subscription (or scope it to specific vault RGs)
az role assignment create --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Site Recovery Reader" --scope /subscriptions/$SUB