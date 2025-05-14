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

try {
    Write-Host "`n🔐 Please log in to Azure..."
    Connect-AzAccount -TenantId $tenantId -ErrorAction Stop
    Write-Host "`n✅ Successfully authenticated to Azure." -ForegroundColor Green
} catch {
    Write-Error "`n❌ Failed to authenticate to Azure. Please check your login credentials. Error: $_"
    exit
}

$subscriptionId = $null
try {
    # Ensure the subscription context is set
    $subscription = Get-AzSubscription | Where-Object { $_.TenantId -eq $tenantId } | Select-Object -First 1
    if (-not $subscription) {
        Write-Error "❌ No subscription found for tenant $tenantId."
        exit
    }
    Set-AzContext -Subscription $subscription.Id -ErrorAction Stop
    Write-Host "`n✅ Successfully set context for subscription $($subscription.Name) ($($subscription.Id))." -ForegroundColor Green
    $subscriptionId = $subscription.Id
} catch {
    Write-Error "❌ Failed to set subscription context. Error: $_"
    exit
}

$resourceGroupName = "$clientCode-Logs-RG"
$workspaceName = "$clientCode-Logs-Workspace"
$location = "eastus"
$dcrName = "$clientCode-Windows-Event-DCR"
$dcrRuleId = (New-Guid).Guid

# Register Microsoft.Insights provider before creating DCR
try {
    Write-Host "🔄 Registering Microsoft.Insights provider for subscription $($subscription.Id)..."
    Register-AzResourceProvider -ProviderNamespace Microsoft.Insights -ErrorAction Stop
    Write-Host "✅ Successfully registered Microsoft.Insights provider." -ForegroundColor Green
} catch {
    Write-Error "❌ Failed to register Microsoft.Insights provider. Error: $_"
    exit
}

# Create Resource Group (if not exists)
if (-not (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Host "Creating Resource Group: $resourceGroupName..."
    New-AzResourceGroup -Name $resourceGroupName -Location $location
}

# Create Log Analytics Workspace
Write-Host "Creating Log Analytics Workspace: $workspaceName..."
$workspace = New-AzOperationalInsightsWorkspace -Location $location -ResourceGroupName $resourceGroupName -Name $workspaceName -Sku PerGB2018 -RetentionInDays 30
#
# Create the Data Collection Rule (DCR)
Write-Host "Creating Data Collection Rule: $dcrName..."
$dcrDataFlow = @(
    @{
        streams = @("Microsoft-Windows-Event")
        dataSources = @{
            logFiles = @(
                @{
                    streams = @("Microsoft-Windows-Event")
                    logNames = @("System", "Application")
                }
            )
        }
        destinations = @{
            logAnalytics = @(
                @{
                    workspaceResourceId = $workspace.ResourceId
                }
            )
        }
    }
)


    try {
        $dcr = New-AzDataCollectionRule -ResourceGroupName $resourceGroupName -Location $location -Name $dcrName `
            -DataFlow $dcrDataFlow `
            -Description "Data collection rule for $clientCode" -ErrorAction Stop
        Write-Host "`n✅ Successfully created Data Collection Rule: $($dcr.Name)" -ForegroundColor Green
    } catch {
        Write-Error "❌ Failed to create Data Collection Rule. Error: $_"
        
        # Print detailed exception information
        if ($_.Exception -ne $null) {
            Write-Host "⚠️ Exception Type:" ($_.Exception.GetType().FullName)
            Write-Host "⚠️ Exception Message:" $_.Exception.Message
            Write-Host "⚠️ Stack Trace:" $_.Exception.StackTrace
            if ($_.Exception.InnerException -ne $null) {
                Write-Host "⚠️ Inner Exception:" $_.Exception.InnerException.Message
            }
        }

        # Print DCR DataFlow definition for review
        Write-Host "⚠️ DCR DataFlow:"
        Write-Host ($dcrDataFlow | ConvertTo-Json -Depth 10)
        Write-Host "⚠️ Workspace ID:"
        Write-Host $workspace.ResourceId
        Write-Host "⚠️ Resource Group Name:"
        Write-Host $resourceGroupName
        Write-Host "⚠️ Location:"
        Write-Host $location
        exit
    }



# Assign the DCR to all resources in the tenant
Write-Host "Assigning Data Collection Rule to all resources in the tenant..."
$allSubscriptions = Get-AzSubscription
foreach ($subscription in $allSubscriptions) {
    Set-AzContext -Subscription $subscription.Id
    $resources = Get-AzResource
    foreach ($resource in $resources) {
        if ($resource.ResourceType -eq "Microsoft.Compute/virtualMachines") {
            Write-Host "Assigning DCR to: $($resource.Name)..."
            New-AzDataCollectionRuleAssociation -ResourceId $resource.Id -RuleId $dcr.Id -AssociationName "$($resource.Name)-$dcrName" -ErrorAction Stop
        }
    }
}

Write-Host "Data Collection Rule setup completed."
