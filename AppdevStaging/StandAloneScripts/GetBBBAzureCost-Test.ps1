Connect-AzAccount -TenantId "27f318ae-79fe-4219-aa14-689300d7365c"

# Billing scope
$BillingAccountId = "DYGY-A77Q-BG7-PGB"
$BillingProfileId = "BitByBitComputerConsultants"
$scope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/billingProfiles/$BillingProfileId"

# Get token
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{ Authorization = "Bearer $token" }

# Query cost
$uri = "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
$body = @{
    type = "Usage"
    timeframe = "MonthToDate"
    dataset = @{
        granularity = "Daily"
        aggregation = @{
            totalCost = @{
                name = "PreTaxCost"
                function = "Sum"
            }
        }
    }
} | ConvertTo-Json -Depth 10

$result = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -ContentType "application/json"

$result.properties.rows