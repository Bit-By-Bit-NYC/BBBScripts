<# 
.SYNOPSIS
  Audits Azure Lighthouse external access for a subscription:
  - Lists registrationAssignments
  - Expands registrationDefinitions
  - Maps roleDefinitionId -> human role name
  - Outputs a table and optional CSV

.NOTES
  Requires: Azure CLI (az) logged in with rights to read ManagedServices on the target subscription.
#>

param(
  [Parameter(Mandatory=$false)]
  [string]$SubscriptionIdOrName,

  [Parameter(Mandatory=$false)]
  [string]$CsvPath = ""
)

function Ensure-AzCli {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found in PATH."
  }
}

function Invoke-AzJson {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$false)][string]$Query = ""
  )
  $args = @("rest","--method","get","--url",$Url,"-o","json")
  if ($Query) { $args += @("--query",$Query) }
  $raw = az @args 2>$null
  if (-not $raw) { return $null }
  return $raw | ConvertFrom-Json
}

function Get-RoleName {
  param([Parameter(Mandatory=$true)][string]$RoleDefinitionId)
  # Cache lookups to avoid repeated calls
  if (-not $script:RoleCache) { $script:RoleCache = @{} }
  if ($script:RoleCache.ContainsKey($RoleDefinitionId)) { return $script:RoleCache[$RoleDefinitionId] }

  $json = az role definition list --name $RoleDefinitionId --query "[0].roleName" -o tsv 2>$null
  if (-not $json) { $json = "<unknown>" }
  $script:RoleCache[$RoleDefinitionId] = $json
  return $json
}

try {
  Ensure-AzCli

  if (-not $SubscriptionIdOrName) {
    $SubscriptionIdOrName = Read-Host "Enter Subscription ID or Name"
  }

  Write-Host "Setting subscription context to '$SubscriptionIdOrName'..." -ForegroundColor Cyan
  az account set --subscription "$SubscriptionIdOrName" | Out-Null

  $acct = az account show -o json | ConvertFrom-Json
  if (-not $acct) { throw "Unable to read current account. Are you logged in?" }
  $subId = $acct.id
  $scope = "/subscriptions/$subId"
  Write-Host "Subscription: $($acct.name)  ($subId)" -ForegroundColor Green

  Write-Host "`nDiscovering Lighthouse registration assignments..." -ForegroundColor Cyan
  $assignments = Invoke-AzJson -Url "https://management.azure.com/subscriptions/$subId/providers/Microsoft.ManagedServices/registrationAssignments?api-version=2020-02-01-preview" -Query "value[].{id:id, regDefId:properties.registrationDefinitionId}"
  if (-not $assignments -or $assignments.Count -eq 0) {
    Write-Warning "No Lighthouse registration assignments found on this subscription."
    return
  }

  $rows = @()
  $i = 0
  foreach ($a in $assignments) {
    $i++
    Write-Host ("[{0}/{1}] Expanding registrationDefinition {2}" -f $i, $assignments.Count, $a.regDefId) -ForegroundColor Yellow

    $def = Invoke-AzJson -Url ("https://management.azure.com{0}?api-version=2020-02-01-preview" -f $a.regDefId)
    if (-not $def) { 
      Write-Warning "  Unable to fetch definition $($a.regDefId)"
      continue 
    }

    $offer = $def.properties.registrationDefinitionName
    $providerTenant = $def.properties.managedByTenantId
    $authz = $def.properties.authorizations
    if (-not $authz) { continue }

    foreach ($auth in $authz) {
      $roleId = $auth.roleDefinitionId
      $roleName = Get-RoleName -RoleDefinitionId $roleId

      $rows += [pscustomobject]@{
        SubscriptionName       = $acct.name
        SubscriptionId         = $subId
        Scope                  = $scope
        Offer                  = $offer
        ProviderTenantId       = $providerTenant
        PrincipalDisplayName   = $auth.principalIdDisplayName
        ProviderPrincipalId    = $auth.principalId
        RoleDefinitionId       = $roleId
        RoleName               = $roleName
        RegistrationDefinition = $a.regDefId
        RegistrationAssignment = $a.id
      }
    }
  }

  if ($rows.Count -eq 0) {
    Write-Warning "No authorizations found in the Lighthouse definitions."
    return
  }

  # Nice on-screen table
  $rows | Sort-Object Offer, RoleName, PrincipalDisplayName |
    Format-Table SubscriptionName, Offer, PrincipalDisplayName, RoleName, ProviderPrincipalId, ProviderTenantId -AutoSize

  if ($CsvPath) {
    $rows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8
    Write-Host "`nSaved CSV -> $CsvPath" -ForegroundColor Green
  } else {
    # Default CSV next to the script if path not provided
    $defaultCsv = Join-Path -Path (Get-Location) -ChildPath ("Lighthouse-ExternalAccess-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $rows | Export-Csv -NoTypeInformation -Path $defaultCsv -Encoding UTF8
    Write-Host "`nSaved CSV -> $defaultCsv" -ForegroundColor Green
  }

  Write-Host "`nDone." -ForegroundColor Green
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
