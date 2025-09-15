<# =====================================================================
 Monthly Azure Cost by ResourceType (granularity=None) with Tags (REST)
 - Single tenant login, single token reused
 - Only the specific subscriptions you list (3bExam-2022 removed)
 - Month default: 2025-06 (override with -Month 'YYYY-MM')
 - Outputs: per-sub rows + combined totals; CSVs
===================================================================== #>

param(
  [string]$Month = '2025-06'   # format YYYY-MM
)

# --------- Tenant and targeted subscriptions (your list, minus 3bExam-2022) ----------
$TenantId = '27f318ae-79fe-4219-aa14-689300d7365c'
$Subscriptions = @(
  '44a07cf4-801a-4ba5-8059-4d916b5f6eaa',  # App Dev
  '5a8f2111-71ad-42fb-a6e1-58d3676ca6ad',  # BitByBit-Synnex-2021
  '98a534ec-4bbd-461f-b87d-55d836a38a57'   # BitByBit-Synnex-Telco
)

# Clean any stale context so Az doesn't try to enumerate everything
Disable-AzContextAutosave -Scope Process | Out-Null
Clear-AzContext -Scope Process -Force

# Option A (recommended): set a default sub for login (persists across sessions)
Update-AzConfig -DefaultSubscriptionForLogin $($Subscriptions[0]) -Scope CurrentUser | Out-Null
Connect-AzAccount -TenantId $TenantId | Out-Null

# Ensure the context is that default sub; no interactive picker
Set-AzContext -TenantId $TenantId -Subscription $($Subscriptions[0]) -Force | Out-Null

# Single ARM token reused for all REST calls
$Token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
$Headers = @{ Authorization = "Bearer $Token" }



# --------- Helpers ----------
function Invoke-WithRetry {
  param([scriptblock]$Script,[int]$MaxAttempts=6,[int]$BaseDelaySec=2)
  $attempt=0
  while ($true) {
    try { $attempt++; return & $Script }
    catch {
      $resp=$_.Exception.Response; $code=$null; $body=$null
      if ($resp) {
        $code=$resp.StatusCode.value__
        try { $reader=New-Object IO.StreamReader($resp.GetResponseStream()); $body=$reader.ReadToEnd() } catch {}
      }
      if ($code -in 429,408,500,503) {
        if ($attempt -ge $MaxAttempts) { throw }
        $delay=[int]([math]::Pow(2,$attempt-1)*$BaseDelaySec)
        Write-Warning "HTTP $code. Retry $attempt/$MaxAttempts in $delay sec..."
        Start-Sleep -Seconds $delay
      } else {
        if ($code) { Write-Warning "HTTP $code body: $body" }
        throw
      }
    }
  }
}

function Get-SubName {
  param([string]$SubId)
  $uri = "https://management.azure.com/subscriptions/$SubId?api-version=2020-01-01"
  try { (Invoke-WithRetry { Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers }).displayName }
  catch { $SubId }
}

# --------- Cost Management query (monthly totals by ResourceType + Tags) ----------
$QueryApiVersion = '2023-03-01'
$BodyJson = @{
  type       = 'Usage'
  timeframe  = 'Custom'
  timePeriod = @{ from = $from; to = $to }
  dataset    = @{
    granularity = 'None'
    aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } # change name -> 'AmortizedCost' if preferred
    grouping    = @(@{ type='Dimension'; name='ResourceType' })
    include     = @('Tags')   # request Tag:* columns
    # configuration = @{ columns = @('ResourceType','Currency','Cost','Tags') }  # optional pinning
  }
} | ConvertTo-Json -Depth 10

# --------- Main loop ----------
$resultRows = New-Object System.Collections.Generic.List[object]

foreach ($subId in $Subscriptions) {
  $subName = Get-SubName -SubId $subId
  Write-Host ("→ {0} ({1})" -f $subName,$subId) -ForegroundColor Yellow

  $scopeUri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=$QueryApiVersion"

  $resp = $null
  try {
    $resp = Invoke-WithRetry { Invoke-RestMethod -Method Post -Uri $scopeUri -Headers $Headers -Body $BodyJson -ContentType 'application/json' }
  } catch {
    Write-Warning "Query failed for sub $subName ($subId): $($_.Exception.Message)"
    continue
  }

  $props = $resp.properties
  if (-not $props -or -not $props.columns -or -not $props.rows) { Write-Host "  (no data returned)" -ForegroundColor DarkGray; continue }

  # Column map
  $colIx=@{}; for ($i=0; $i -lt $props.columns.Count; $i++){ $colIx[$props.columns[$i].name]=$i }
  function Col($row,$name){ if($colIx.ContainsKey($name)){ $row[$colIx[$name]] } else { $null } }

  foreach ($row in $props.rows) {
    # Build tags CSV from Tag:* columns
    $tagPairs = foreach ($c in $props.columns) {
      if ($c.name -like 'Tag:*') {
        $v = $row[$colIx[$c.name]]
        if ($v) { "$($c.name.Substring(4))=$v" }
      }
    }
    $tagCsv = ($tagPairs | Where-Object { $_ } | Sort-Object -Unique) -join ', '

    $resultRows.Add([pscustomobject]@{
      SubscriptionName = $subName
      SubscriptionId   = $subId
      ResourceType     = (Col $row 'ResourceType') ?? 'Unknown'
      Currency         = (Col $row 'Currency')     ?? ''
      MonthStart       = $from
      MonthEnd         = $to
      TotalCost        = [decimal]((Col $row 'totalCost') ?? (Col $row 'Cost') ?? 0)
      Tags             = $tagCsv
    })
  }
}

# --------- Output / CSVs ----------
if ($resultRows.Count -eq 0) {
  Write-Warning "No rows returned. (Check access, subscription IDs, or whether those subs had charges in $Month.)"
  return
}

$combined =
  $resultRows |
  Group-Object ResourceType, Currency |
  ForEach-Object {
    [pscustomobject]@{
      ResourceType = $_.Group[0].ResourceType
      Currency     = $_.Group[0].Currency
      TotalCost    = ($_.Group | Measure-Object TotalCost -Sum).Sum
      TagKeysSeen  = ($_.Group.Tags -split ',\s*' | ForEach-Object { ($_ -split '=',2)[0] } | Where-Object { $_ } | Sort-Object -Unique) -join ','
    }
  } | Sort-Object TotalCost -Descending

Write-Host "`n---- Per subscription, per resource type ----" -ForegroundColor Green
$resultRows | Sort-Object SubscriptionName, ResourceType | Format-Table -AutoSize

Write-Host "`n---- Combined by resource type (all targeted subs) ----" -ForegroundColor Green
$combined | Format-Table -AutoSize

$stamp  = (Get-Date -Format 'yyyyMMdd-HHmmss')
$perCsv = "azure-costs-$($Month)-by-resourcetype-per-sub-$stamp.csv"
$allCsv = "azure-costs-$($Month)-by-resourcetype-combined-$stamp.csv"
$resultRows | Export-Csv $perCsv -NoTypeInformation
$combined   | Export-Csv $allCsv -NoTypeInformation

Write-Host "`nSaved:" -ForegroundColor Cyan
Write-Host "  $perCsv"
Write-Host "  $allCsv"