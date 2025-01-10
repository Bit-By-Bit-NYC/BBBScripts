param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,
    
    [Parameter(Mandatory = $true)]
    [string]$HyperVHost
)

# Import the FailoverClusters module
Import-Module FailoverClusters

# Function to wait for the VMs to evacuate
function WaitForEvacuation {
    param(
        [string]$NodeName,
        [string]$ClusterName
    )

    Write-Output "Waiting for VMs to evacuate from $NodeName on cluster $ClusterName..."

    while ($true) {
        $runningVMs = Get-ClusterGroup -Cluster $ClusterName | Where-Object {
            $_.OwnerNode.Name -eq $NodeName -and $_.GroupType -eq 'VirtualMachine'
        }

        if ($runningVMs.Count -eq 0) {
            Write-Output "All VMs have been evacuated from $NodeName."
            break
        }

        # Display the VMs that are still on the node
        Write-Output "Still evacuating VMs:"
        $runningVMs | ForEach-Object { Write-Output " - $($_.Name)" }

        Start-Sleep -Seconds 5
    }
}

# Function to wait for the host to come back online
function WaitForHostOnline {
    param(
        [string]$NodeName,
        [string]$ClusterName
    )

    Write-Output "Waiting for $NodeName to come back online on cluster $ClusterName..."

    while ($true) {
        try {
            $nodeStatus = Get-ClusterNode -Cluster $ClusterName -Name $NodeName
               if ($nodeStatus.State -in @('Up', 'Paused')) {
                Write-Output "$NodeName is back online."
                break
            } else {
                Write-Output "$NodeName is still offline. Waiting..."
            }
        } catch {
            Write-Output "Error checking the cluster node: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 10
    }
}

# Put the host into maintenance mode
Write-Output "Putting $HyperVHost into maintenance mode on cluster $ClusterName..."
Suspend-ClusterNode -Cluster $ClusterName -Name $HyperVHost -Drain

# Wait for the VMs to evacuate
WaitForEvacuation -NodeName $HyperVHost -ClusterName $ClusterName

# Reboot the host
Write-Output "Rebooting $HyperVHost..."
Restart-Computer -ComputerName $HyperVHost -Force -Wait

# Wait for the host to come back online
WaitForHostOnline -NodeName $HyperVHost -ClusterName $ClusterName

# Take the host out of maintenance mode
Write-Output "Taking $HyperVHost out of maintenance mode on cluster $ClusterName..."
Resume-ClusterNode -Cluster $ClusterName -Name $HyperVHost

Write-Output "Operation complete. $HyperVHost is now out of maintenance mode on cluster $ClusterName."
