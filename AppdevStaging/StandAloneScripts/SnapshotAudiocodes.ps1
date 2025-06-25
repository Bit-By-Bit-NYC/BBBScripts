# CONFIGURATION
$subscriptionId = "98a534ec-4bbd-461f-b87d-55d836a38a57"
$resourceGroup = "Audiocodes6"
$vmName = "Audiocodes6-sbc"
$diskName = "Audiocodes6-sbc_OsDisk_1_556090ed91b843c8bc1fce17af65fb31"
$retentionDays = 30

# Set context11
Connect-AzAccount
Set-AzContext -SubscriptionId $subscriptionId

# Create snapshot name with timestamp
$dateStr = Get-Date -Format "yyyyMMdd-HHmmss"
$snapshotName = "$diskName-snap-$dateStr"

# Get the disk
$disk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $diskName

# Create the snapshot config
$snapshotConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy

# Create the snapshot
New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $resourceGroup | Out-Null
Write-Host "Snapshot $snapshotName created."

# Cleanup old snapshots
$snapshots = Get-AzSnapshot -ResourceGroupName $resourceGroup | Where-Object {
    $_.SnapshotType -eq "Full" -and $_.Name -like "$diskName-snap-*"
}

$now = Get-Date
foreach ($snap in $snapshots) {
    $created = $snap.TimeCreated
    if (($now - $created).TotalDays -gt $retentionDays) {
        Remove-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName $snap.Name -Force
        Write-Host "Deleted old snapshot: $($snap.Name)"
    }
}