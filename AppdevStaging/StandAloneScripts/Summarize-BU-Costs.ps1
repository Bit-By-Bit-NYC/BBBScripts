<#
.SYNOPSIS
  Summarize Azure billing cost by BBB-BU tag using RG->BU mapping.

.PARAMETER BillingCsv
  Path to billing CSV (must contain a Resource Group column & a cost column).

.PARAMETER MappingCsv
  Path to Azure resource group mapping CSV (must contain RG name & BBB-BU tag).

.PARAMETER SummaryOut
  Output CSV file for the cost summary (by BBB-BU).

.PARAMETER NoMatchOut
  Output CSV file listing RGs that did not match the mapping (and their total cost).

.PARAMETER ConfigPath
  Optional path to a simple key=value config file overriding any parameters.
  Supported keys: BillingCsv, MappingCsv, SummaryOut, NoMatchOut

.NOTES
  Designed to work in Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
  [string]$BillingCsv = "./billing-sample.csv",
  [string]$MappingCsv = "./Azureresourcegroups.csv",
  [string]$SummaryOut = "./bbb_bu_cost_summary.csv",
  [string]$NoMatchOut = "./nomatchresourcegroup.csv",
  [string]$ConfigPath
)

function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level='INFO')
  $ts = (Get-Date).ToString("s")
  switch ($Level) {
    'INFO'  { Write-Host "[$ts] $Message" }
    'WARN'  { Write-Warning "$Message" }
    'ERROR' { Write-Error "$Message" }
  }
}

function Get-Config {
  param([string]$Path)
  if (-not $Path) { return @{} }
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Log "Config file not found: $Path (continuing with CLI/default params)" WARN
    return @{}
  }
  $pairs = @{}
  Get-Content -LiteralPath $Path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $kv = $line -split '=', 2
    if ($kv.Count -eq 2) {
      $pairs[$kv[0].Trim()] = $kv[1].Trim()
    }
  }
  return $pairs
}

# Apply config (if provided)
$config = Get-Config -Path $ConfigPath
if ($config.ContainsKey('BillingCsv')) { $BillingCsv = $config['BillingCsv'] }
if ($config.ContainsKey('MappingCsv')) { $MappingCsv = $config['MappingCsv'] }
if ($config.ContainsKey('SummaryOut')) { $SummaryOut = $config['SummaryOut'] }
if ($config.ContainsKey('NoMatchOut')) { $NoMatchOut = $config['NoMatchOut'] }

# Validate files
if (-not (Test-Path -LiteralPath $BillingCsv)) { Write-Log "Billing CSV not found: $BillingCsv" ERROR; exit 1 }
if (-not (Test-Path -LiteralPath $MappingCsv)) { Write-Log "Mapping CSV not found: $MappingCsv" ERROR; exit 1 }

Write-Log "Loading billing file: $BillingCsv"
$billing = Import-Csv -LiteralPath $BillingCsv
Write-Log "Loaded billing rows: $($billing.Count)"

Write-Log "Loading mapping file: $MappingCsv"
$mapping = Import-Csv -LiteralPath $MappingCsv
Write-Log "Loaded mapping rows: $($mapping.Count)"

# Case-insensitive column resolver
function Get-ColumnName {
  param(
    [object]$FirstRow,
    [string[]]$Candidates
  )
  $cols = @()
  $FirstRow.PSObject.Properties | ForEach-Object { $cols += $_.Name }
  foreach ($cand in $Candidates) {
    $hit = $cols | Where-Object { $_ -ieq $cand } | Select-Object -First 1
    if ($hit) { return $hit }
  }
  # Fuzzy: contains both 'resource' and 'group'
  $hit = $cols | Where-Object { $_ -match '(?i)resource' -and $_ -match '(?i)group' } | Select-Object -First 1
  if ($hit) { return $hit }
  return $null
}

# Find RG columns
$billRgCol = Get-ColumnName -FirstRow $billing[0] -Candidates @('ResourceGroupName','ResourceGroup','Resource Group','RG','RGName')
if (-not $billRgCol) { Write-Log "Could not find a Resource Group column in billing CSV." ERROR; Write-Host "Billing Columns: $((($billing[0].psobject.properties).name) -join ', ')"; exit 1 }

# For mapping, your sample shows RGs under 'NAME'
$mapRgCol  = Get-ColumnName -FirstRow $mapping[0] -Candidates @('NAME','ResourceGroupName','ResourceGroup','Resource Group')
if (-not $mapRgCol) { Write-Log "Could not find a Resource Group column in mapping CSV." ERROR; Write-Host "Mapping Columns: $((($mapping[0].psobject.properties).name) -join ', ')"; exit 1 }

# Find BU column in mapping
$mapBuCol = ($mapping[0].psobject.Properties.Name | Where-Object { $_ -match '(?i)^BBB-?BU' } | Select-Object -First 1)
if (-not $mapBuCol) { $mapBuCol = ($mapping[0].psobject.Properties.Name | Where-Object { $_ -match '(?i)business\s*unit|^BU$' } | Select-Object -First 1) }
if (-not $mapBuCol) { Write-Log "Could not find a BBB-BU tag column in mapping CSV." ERROR; Write-Host "Mapping Columns: $((($mapping[0].psobject.properties).name) -join ', ')"; exit 1 }

# Find cost column in billing
function Get-CostColumn {
  param([object]$FirstRow)
  $cols = $FirstRow.psobject.Properties.Name
  $preferred = @('CostInBillingCurrency','CostUSD','Cost','PreTaxCost','ExtendedCost','ResourceCost','CostInUSD','EffectivePrice','ChargeAmount','BillingAmount')
  foreach ($c in $preferred) {
    $hit = $cols | Where-Object { $_ -ieq $c } | Select-Object -First 1
    if ($hit) { return $hit }
  }
  # Any column containing 'cost'
  $hit = $cols | Where-Object { $_ -match '(?i)cost' } | Select-Object -First 1
  return $hit
}
$costCol = Get-CostColumn -FirstRow $billing[0]
if (-not $costCol) { Write-Log "Could not detect a cost column in billing CSV." ERROR; Write-Host "Billing Columns: $((($billing[0].psobject.properties).name) -join ', ')"; exit 1 }

Write-Log "Using columns -> Billing RG: '$billRgCol'  | Mapping RG: '$mapRgCol'  | BU: '$mapBuCol'  | Cost: '$costCol'"

# Normalizers
function Normalize-RG([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return $s.Trim().ToLower()
}
function Normalize-Loose([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return -join ($s.ToLower().ToCharArray() | Where-Object { $_ -match '[a-z0-9]' })
}
function To-Decimal($v) {
  if ($null -eq $v) { return 0 }
  $str = [string]$v
  # Strip currency symbols and thousands separators; keep digits, minus, and dot
  $str = ($str -replace '[^0-9\.\-]', '')
  if ([string]::IsNullOrWhiteSpace($str)) { return 0 }
  try { return [decimal]::Parse($str, [System.Globalization.CultureInfo]::InvariantCulture) }
  catch { return 0 }
}

# Build RG->BU map (both strict & loose keys)
$rgToBu = @{}
$rgToBuLoose = @{}
foreach ($row in $mapping) {
  $rg = Normalize-RG $row.$mapRgCol
  $bu = $row.$mapBuCol
  if ($rg -and $bu) {
    if (-not $rgToBu.ContainsKey($rg)) { $rgToBu[$rg] = $bu }
    $loose = Normalize-Loose $row.$mapRgCol
    if ($loose -and -not $rgToBuLoose.ContainsKey($loose)) { $rgToBuLoose[$loose] = $bu }
  }
}

# Enrich billing rows with BU and accumulate unmatched
$enriched = @()
$unmatched = @()

foreach ($row in $billing) {
  $rgName = $row.$billRgCol
  $cost   = To-Decimal $row.$costCol
  $norm   = Normalize-RG $rgName
  $buVal  = $null

  if ($norm -and $rgToBu.ContainsKey($norm)) {
    $buVal = $rgToBu[$norm]
  } else {
    # Try loose match
    $loose = Normalize-Loose $rgName
    if ($loose -and $rgToBuLoose.ContainsKey($loose)) {
      $buVal = $rgToBuLoose[$loose]
    }
  }

  if ($buVal) {
    $enriched += [pscustomobject]@{
      ResourceGroupName = $rgName
      BBBBU             = $buVal
      Cost              = $cost
    }
  } else {
    $unmatched += [pscustomobject]@{
      ResourceGroupName = $rgName
      Cost              = $cost
    }
  }
}

# Summarize by BU
$summary = $enriched |
  Group-Object BBBBU |
  ForEach-Object {
    [pscustomobject]@{
      'BBB-BU' = $_.Name
      'TotalCost' = ($_.Group | Measure-Object -Property Cost -Sum).Sum
    }
  } |
  Sort-Object -Property TotalCost -Descending

# Summarize unmatched by RG (so you can see where to add mappings)
$unmatchedSummary = $unmatched |
  Group-Object ResourceGroupName |
  ForEach-Object {
    [pscustomobject]@{
      'ResourceGroupName' = $_.Name
      'TotalCost'         = ($_.Group | Measure-Object -Property Cost -Sum).Sum
    }
  } |
  Sort-Object -Property TotalCost -Descending

# Output to screen
Write-Host ""
Write-Host "===== BBB-BU Cost Summary ====="
if ($summary) {
  $summary | Format-Table -AutoSize
} else {
  Write-Host "(No matched rows.)"
}

Write-Host ""
if ($unmatchedSummary.Count -gt 0) {
  Write-Log "Unmatched resource groups found: $($unmatchedSummary.Count)" WARN
  $unmatchedSummary | Format-Table -AutoSize
} else {
  Write-Log "No unmatched resource groups." INFO
}

# Write CSVs
try {
  $summary | Export-Csv -LiteralPath $SummaryOut -NoTypeInformation -Encoding UTF8
  Write-Log "Wrote summary CSV: $SummaryOut"
} catch {
  Write-Log "Failed to write $SummaryOut. $_" ERROR
}

try {
  # Always create the file; write empty headers if none
  if ($unmatchedSummary.Count -gt 0) {
    $unmatchedSummary | Export-Csv -LiteralPath $NoMatchOut -NoTypeInformation -Encoding UTF8
  } else {
    # create empty with headers
    @([pscustomobject]@{ ResourceGroupName=''; TotalCost=0 })[0..-1] | Export-Csv -LiteralPath $NoMatchOut -NoTypeInformation -Encoding UTF8
  }
  Write-Log "Wrote unmatched CSV: $NoMatchOut"
} catch {
  Write-Log "Failed to write $NoMatchOut. $_" ERROR
}

Write-Log "Completed."