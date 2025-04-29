# --- CONFIGURATION ---
$tenantId = "27f318ae-79fe-4219-aa14-689300d7365c"
$clientId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1"  # bbb-svc-reboot_patch

# Prompt for client secret securely
$clientSecret = Read-Host "Enter client secret for the service principal" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential ($clientId, $clientSecret)

# --- LOGIN ---
Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $cred

# --- ENUMERATE ALL ACCESSIBLE SUBSCRIPTIONS (includes delegated via Lighthouse) ---
$subscriptions = Get-AzSubscription

# --- INIT RESULTS ---
$allResults = @()

foreach ($sub in $subscriptions) {
    Write-Host "`n>>> Subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id

    # Get all Log Analytics workspaces
    $workspaces = Get-AzOperationalInsightsWorkspace

    foreach ($ws in $workspaces) {
        Write-Host "    -> Workspace: $($ws.Name)" -ForegroundColor Yellow

        # Reboot query (Event ID 6005 = system start)

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
# --- DISPLAY RESULTS ---
$allResults | Format-Table Computer, LastBoot, LastPatchTime, PatchDetails, Subscription -AutoSize

# --- Optional CSV Export ---
$allResults | Export-Csv -Path ".\RebootStatus-All.csv" -NoTypeInformation
