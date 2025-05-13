# --- CONFIGURATION: Pull Tenants from Azure Function ---
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

# --- DISPLAY OPTIONS ---
Write-Host "`nAvailable Tenants:"
foreach ($key in $tenants.Keys | Sort-Object) {
    $t = $tenants[$key]
    Write-Host "$key. $($t.Name) [$($t.Id)]"
}

# --- USER SELECTS TENANT ---
[int]$selection = Read-Host "`nSelect a tenant number"
if (-not $tenants.ContainsKey($selection.ToString())) {
    Write-Error "Invalid selection. Exiting..."
    exit
}

$selectedTenant = $tenants[$selection.ToString()]
$tenantId = $selectedTenant.Id
$tenantName = $selectedTenant.Name

Write-Host "`nUsing tenant: $tenantName ($tenantId)" -ForegroundColor Green

# --- SERVICE PRINCIPAL LOGIN ---
$clientId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1"  # bbb-svc-reboot_patch
$clientSecret = Read-Host "Enter client secret for the service principal" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential ($clientId, $clientSecret)

Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $cred

# --- ENUMERATE ALL ACCESSIBLE SUBSCRIPTIONS ---
$subscriptions = Get-AzSubscription
$allResults = @()

foreach ($sub in $subscriptions) {
    Write-Host "`n>>> Subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id

    # Get Log Analytics Workspaces
    $workspaces = Get-AzOperationalInsightsWorkspace

    foreach ($ws in $workspaces) {
        Write-Host "    -> Workspace: $($ws.Name)" -ForegroundColor Yellow

        # KQL Query
        $kql = @"
let rebootData = 
    Event
    | where EventLog == "System"
    | where EventID in (6005, 6006)
    | extend ComputerName = tolower(Computer)
    | summarize LastReboot = max(TimeGenerated), RebootComputer = any(Computer) by ComputerName;

let patchData = 
    Event
    | where EventLog == "System"
    | where EventID == 19
    | where not(RenderedDescription has "Defender" or RenderedDescription has "Security Intelligence Update")
    | where RenderedDescription has "Installation Successful: Windows successfully installed the following update" and RenderedDescription has "Cumulative" or RenderedDescription has "Security"
    | extend ComputerName = tolower(Computer)
    | summarize arg_max(TimeGenerated, RenderedDescription, Computer) by ComputerName
    | project ComputerName, LastPatchTime = TimeGenerated, PatchDetails = RenderedDescription, PatchComputer = Computer;

rebootData
| join kind=fullouter patchData on ComputerName
| project 
    Computer = coalesce(RebootComputer, PatchComputer),
    LastReboot = coalesce(LastReboot, datetime(null)),
    LastPatchTime = coalesce(LastPatchTime, datetime(null)),
    PatchDetails = coalesce(PatchDetails, "No patch record found")
"@

        try {
            $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $kql
            if ($result.Results.Count -gt 0) {
                $result.Results | ForEach-Object {
                    $_ | Add-Member -NotePropertyName "Workspace" -NotePropertyValue $ws.Name
                    $_ | Add-Member -NotePropertyName "Subscription" -NotePropertyValue $sub.Name
                    $allResults += $_
                }
            }
        } catch {
            Write-Warning "    ! Failed to query $($ws.Name): $_"
        }
    }
}

# --- DISPLAY RESULTS ---
$sortedResults = $allResults | Sort-Object LastReboot
$mdTable = @"
| Computer | Last Reboot | Last Patch | Update Summary | Subscription |
|----------|-------------|------------|----------------|--------------|
"@

foreach ($row in $sortedResults) {
    $computer = $row.Computer
    $reboot = if ($row.LastReboot) { (Get-Date -Date $row.LastReboot).ToString("yyyy-MM-dd") } else { "Missing" }
    $patch = if ($row.LastPatchTime) { (Get-Date -Date $row.LastPatchTime).ToString("yyyy-MM-dd") } else { "Missing" }

    $patchSummary = $row.PatchDetails -replace "Installation Successful: Windows successfully installed the following update:\s*", ""
    $patchSummary = if ($patchSummary.Length -gt 60) { $patchSummary.Substring(0, 60) + "..." } else { $patchSummary }

    $subscription = $row.Subscription
    $mdTable += "| $computer | $reboot | $patch | $patchSummary | $subscription |`n"
}

# Export CSV
$allResults | Export-Csv -Path ".\RebootStatus-All.csv" -NoTypeInformation

# Output Markdown to screen
Write-Host "`n--- Markdown Table Output ---`n"
$mdTable