# Import necessary modules
Import-Module Az.Accounts
Import-Module Az.OperationalInsights
Import-Module Az.Monitor

# Prompt for tenant selection
$functionUrl = "https://func-bbb-tenantapi.azurewebsites.net/api/GetTenants?code=HSq9Mt_Hgd0ISxi7r-5PwGxJ8U-9oPq7EcwGypmCsHzKAzFu7Xlueg=="
try {
    $response = Invoke-RestMethod -Uri $functionUrl -Method GET
    $tenants = @{}
    $i = 1
    foreach ($tenant in $response) {
        $tenants["$i"] = @{ Name = $tenant.TenantName; Id = $tenant.TenantId }
        $i++
    }
} catch {
    Write-Error "❌ Failed to retrieve tenants: $_"
    exit
}

# Display available tenants
Write-Host "`nAvailable Tenants:"
foreach ($key in $tenants.Keys | Sort-Object) {
    $t = $tenants[$key]
    Write-Host "$key. $($t.Name) [$($t.Id)]"
}

# User selects tenant
[int]$selection = Read-Host "`nSelect a tenant number"
if (-not $tenants.ContainsKey($selection.ToString())) {
    Write-Error "Invalid selection. Exiting..."
    exit
}

$selectedTenant = $tenants[$selection.ToString()]
$tenantId = $selectedTenant.Id
$tenantName = $selectedTenant.Name

Write-Host "`nUsing tenant: $tenantName ($tenantId)" -ForegroundColor Green

# Prompt for Client Code
$clientCode = Read-Host "Enter the Client Code (e.g., SCEMS, GEM, PARIO)"

# Authentication
$clientId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1"  # bbb-svc-reboot_patch
$clientSecret = Read-Host "Enter client secret for the service principal" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential ($clientId, $clientSecret)
Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $cred

# Configuration Variables
$subscriptionId = (Get-AzSubscription | Select-Object -First 1).Id  # Use the first available subscription by default
$resourceGroupName = "$clientCode-Logs-RG"
$workspaceName = "$clientCode-Logs-Workspace"
$location = "eastus"
$dcrName = "$clientCode-Windows-Event-DCR"
$dcrRuleId = (New-Guid).Guid

# Create Resource Group (if not exists)
if (-not (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Host "Creating Resource Group: $resourceGroupName..."
    New-AzResourceGroup -Name $resourceGroupName -Location $location
}

# Create Log Analytics Workspace
Write-Host "Creating Log Analytics Workspace: $workspaceName..."
$workspace = New-AzOperationalInsightsWorkspace -Location $location -ResourceGroupName $resourceGroupName -Name $workspaceName -Sku Standard -RetentionInDays 30

# Create the Data Collection Rule (DCR)
Write-Host "Creating Data Collection Rule: $dcrName..."
$dcrDataFlow = @{
    Streams = @("Microsoft-Windows-Event")
    LogNames = @("System", "Application", "Security")
}
$dcr = New-AzMonitorDataCollectionRule -ResourceGroupName $resourceGroupName -Location $location -Name $dcrName -DataFlow @(
    @{Source = $dcrDataFlow; Destination = @{WorkspaceResourceId = $workspace.ResourceId}}
) -DataCollectionEndpoint $(Get-AzMonitorDataCollectionEndpoint -Location $location).ResourceId

# Assign the DCR to all resources in the tenant
Write-Host "Assigning Data Collection Rule to all resources in the tenant..."
$allSubscriptions = Get-AzSubscription
foreach ($subscription in $allSubscriptions) {
    Set-AzContext -Subscription $subscription.Id
    $resources = Get-AzResource
    foreach ($resource in $resources) {
        if ($resource.ResourceType -eq "Microsoft.Compute/virtualMachines") {
            Write-Host "Assigning DCR to: $($resource.Name)..."
            New-AzMonitorDataCollectionRuleAssociation -ResourceId $resource.Id -DataCollectionRuleName $dcrName -ResourceGroupName $resourceGroupName
        }
    }
}

Write-Host "Data Collection Rule setup completed."
