[CmdletBinding()]
param(
  # Defaults you asked for
  [string] $SubscriptionId = '5a8f2111-71ad-42fb-a6e1-58d3676ca6ad',
  [string] $ResourceGroup  = 'rg-appdev2',

  # Default CSV path: ./AzurePublicIpAddresses.csv next to this script
  [string] $CsvPath = $(Join-Path -Path (Split-Path -Parent $PSCommandPath) -ChildPath 'AzurePublicIpAddresses.csv'),

  # Dry run
  [switch] $WhatIf,

  # If a PIP is Dynamic, convert to Static first (so the IP can be kept)
  [switch] $ForceStatic
)

# Requires: Az.Accounts, Az.Network
# If you see auth/tenant warnings, see the "Sign in to the right tenant" notes below.

# Set context (will warn if not signed in)
Set-AzContext -Subscription $SubscriptionId -ErrorAction SilentlyContinue | Out-Null

# ---- helpers ----
# Flexible column matching (case-insensitive, tolerates spaces)
$ColMap = @{
  Name     = @('NAME','Name')
  Location = @('LOCATION','Location')
}

function Get-ColValue {
  param($row, [string[]]$options)
  foreach ($prop in $row.PSObject.Properties) {
    foreach ($opt in $options) {
      if ($prop.Name -ieq $opt) { return $row.($prop.Name) }
    }
  }
  return $null
}

function Get-PipAssociation {
  param([Microsoft.Azure.Commands.Network.Models.PSPublicIpAddress] $Pip)
  $id = $Pip.IpConfiguration?.Id
  $o = [pscustomobject]@{
    Type='None'; NicName=$null; NicIpConf=$null; LbName=$null; LbFe=$null;
    AgwName=$null; AgwFe=$null; BastionName=$null; BastionIpConf=$null
  }
  if ([string]::IsNullOrWhiteSpace($id)) { return $o }
  if ($id -match '/networkInterfaces/([^/]+)/ipConfigurations/([^/]+)$') { $o.Type='Nic';     $o.NicName=$Matches[1];    $o.NicIpConf=$Matches[2];    return $o }
  if ($id -match '/loadBalancers/([^/]+)/frontendIPConfigurations/([^/]+)$') { $o.Type='Lb';  $o.LbName=$Matches[1];     $o.LbFe=$Matches[2];         return $o }
  if ($id -match '/applicationGateways/([^/]+)/frontendIPConfigurations/([^/]+)$') { $o.Type='Agw'; $o.AgwName=$Matches[1]; $o.AgwFe=$Matches[2];        return $o }
  if ($id -match '/bastionHosts/([^/]+)/ipConfigurations/([^/]+)$') { $o.Type='Bastion';      $o.BastionName=$Matches[1];$o.BastionIpConf=$Matches[2]; return $o }
  return $o
}

# ---- CSV ----
if (-not (Test-Path -Path $CsvPath)) { throw "CSV not found: $CsvPath" }
$rows = Import-Csv -Path $CsvPath
if (-not $rows) { throw "CSV '$CsvPath' is empty." }

foreach ($row in $rows) {
  $name = (Get-ColValue $row $ColMap.Name) -as [string]
  $loc  = (Get-ColValue $row $ColMap.Location) -as [string]
  if ([string]::IsNullOrWhiteSpace($name)) { continue }

  Write-Host "`n==== $name ($loc) ===="

  $pip = Get-AzPublicIpAddress -Name $name -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
  if (-not $pip) { Write-Warning "Not found: $ResourceGroup/$name — skipping."; continue }

  if ($pip.Sku -and $pip.Sku.Name -eq 'Standard') { Write-Host "Already Standard — skipping."; continue }

  $allocation = $pip.PublicIpAllocationMethod    # Static or Dynamic
  $oldIp      = $pip.IpAddress
  $assoc      = Get-PipAssociation $pip

  Write-Host "Plan:"
  Write-Host "  - Disassociate: $($assoc.Type)"
  if ($allocation -eq 'Dynamic') {
    if ($ForceStatic) { Write-Host "  - Change allocation to Static (required to keep IP)" }
    else { Write-Host "  - SKIP: Allocation is Dynamic; re-run with -ForceStatic to convert first."; continue }
  }
  Write-Host "  - Upgrade IN PLACE to Standard (IP should remain: $oldIp)"
  Write-Host "  - Reassociate to original target"
  if ($WhatIf) { continue }

  # 1) Disassociate
  switch ($assoc.Type) {
    'Nic' {
      $nic = Get-AzNetworkInterface -Name $assoc.NicName -ResourceGroupName $ResourceGroup
      $ipc = $nic.IpConfigurations | Where-Object Name -eq $assoc.NicIpConf
      if ($ipc) { $ipc.PublicIpAddress = $null; Set-AzNetworkInterface -NetworkInterface $nic | Out-Null }
    }
    'Lb' {
      $lb = Get-AzLoadBalancer -Name $assoc.LbName -ResourceGroupName $ResourceGroup
      $fe = $lb.FrontendIpConfigurations | Where-Object Name -eq $assoc.LbFe
      if ($fe) { $fe.PublicIpAddress = $null; Set-AzLoadBalancer -LoadBalancer $lb | Out-Null }
    }
    'Agw' {
      $agw = Get-AzApplicationGateway -Name $assoc.AgwName -ResourceGroupName $ResourceGroup
      $fe  = $agw.FrontendIpConfigurations | Where-Object Name -eq $assoc.AgwFe
      if ($fe) { $fe.PublicIpAddress = $null; Set-AzApplicationGateway -ApplicationGateway $agw | Out-Null }
    }
    'Bastion' {
      $bas = Get-AzBastion -Name $assoc.BastionName -ResourceGroupName $ResourceGroup
      $ipc = $bas.IpConfigurations | Where-Object Name -eq $assoc.BastionIpConf
      if ($ipc) { $ipc.PublicIpAddress = $null; Set-AzBastion -InputObject $bas | Out-Null }
    }
    Default { Write-Host "No association detected." }
  }

  # 2) Ensure Static if requested
  if ($allocation -eq 'Dynamic' -and $ForceStatic) {
    $pip.PublicIpAllocationMethod = 'Static'
    Set-AzPublicIpAddress -PublicIpAddress $pip | Out-Null
    $pip = Get-AzPublicIpAddress -Name $name -ResourceGroupName $ResourceGroup
  }

  # 3) Upgrade to Standard (avoid missing-type issues — just set Name)
  if (-not $pip.Sku) { $pip | Add-Member -NotePropertyName Sku -NotePropertyValue ([pscustomobject]@{ Name='Standard' }) }
  else { $pip.Sku.Name = 'Standard' }
  Set-AzPublicIpAddress -PublicIpAddress $pip | Out-Null

  $pipPost = Get-AzPublicIpAddress -Name $name -ResourceGroupName $ResourceGroup
  $newIp   = $pipPost.IpAddress
  Write-Host "Upgraded: $name (IP before: $oldIp, after: $newIp)"

  # 4) Reassociate
  switch ($assoc.Type) {
    'Nic' {
      $nic = Get-AzNetworkInterface -Name $assoc.NicName -ResourceGroupName $ResourceGroup
      $ipc = $nic.IpConfigurations | Where-Object Name -eq $assoc.NicIpConf
      $ipc.PublicIpAddress = $pipPost
      Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
    }
    'Lb' {
      $lb = Get-AzLoadBalancer -Name $assoc.LbName -ResourceGroupName $ResourceGroup
      $fe = $lb.FrontendIpConfigurations | Where-Object Name -eq $assoc.LbFe
      $fe.PublicIpAddress = $pipPost
      Set-AzLoadBalancer -LoadBalancer $lb | Out-Null
    }
    'Agw' {
      $agw = Get-AzApplicationGateway -Name $assoc.AgwName -ResourceGroupName $ResourceGroup
      $fe  = $agw.FrontendIpConfigurations | Where-Object Name -eq $assoc.AgwFe
      $fe.PublicIpAddress = $pipPost
      Set-AzApplicationGateway -ApplicationGateway $agw | Out-Null
    }
    'Bastion' {
      $bas = Get-AzBastion -Name $assoc.BastionName -ResourceGroupName $ResourceGroup
      $ipc = $bas.IpConfigurations | Where-Object Name -eq $assoc.BastionIpConf
      $ipc.PublicIpAddress = $pipPost
      Set-AzBastion -InputObject $bas | Out-Null
    }
  }

  Write-Host "DONE: $name"
}

Write-Host "`nAll rows processed."

