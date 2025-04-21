<#
.SYNOPSIS
Configures recovery options for a Windows service to restart on failure, using
sc.exe failureflag to enable actions for non-crash failures.

.DESCRIPTION
This script uses the potentially undocumented 'sc.exe failureflag' command to set the
flag corresponding to "Enable actions for stops with errors". It then uses the
standard 'sc.exe failure' command to set the first, second, and subsequent failure
actions to 'Restart the service', configure the delay, and set the failure reset period.
Running this script requires administrative privileges.

NOTE: The 'failureflag' subcommand for sc.exe is not officially documented by Microsoft
for standard Windows versions. Its availability or behavior might depend on the specific
OS version or installed management tools (like Kaseya). Use with caution.

.PARAMETER ServiceName
The name of the Windows service to configure (e.g., "Spooler", "wuauserv", "KABITBIT77713442764322").

.PARAMETER DelayMilliseconds
The delay in milliseconds before each restart attempt (Default: 60000ms = 1 minute).

.PARAMETER ResetPeriodSeconds
The time in seconds after which to reset the failure count (Default: 86400s = 1 day).

.EXAMPLE
.\Set-ServiceRecoveryRestart-SC_Flag.ps1 -ServiceName "KABITBIT77713442764322"
Attempts to enable the failure flag using 'sc.exe failureflag' and then configures
the service to restart 60 seconds after the first, second, and subsequent failures,
resetting the failure count after 1 day.

.EXAMPLE
.\Set-ServiceRecoveryRestart-SC_Flag.ps1 -ServiceName "MyCustomService" -DelayMilliseconds 120000 -ResetPeriodSeconds 3600
Attempts to enable the failure flag and then configures "MyCustomService" to restart
120 seconds (2 minutes) after failures, resetting the failure count after 1 hour.

.NOTES
Requires administrative privileges to modify service configurations.
Relies on the 'sc.exe failureflag' command working on the target system.
Uses escaped double quotes (`"`) around the service name passed to sc.exe.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ServiceName,

    [Parameter(Mandatory=$false)]
    [int]$DelayMilliseconds = 60000, # Default: 1 minute

    [Parameter(Mandatory=$false)]
    [int]$ResetPeriodSeconds = 86400  # Default: 1 day
)

#region Check for Administrator Privileges
Write-Verbose "Checking for administrative privileges..."
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run with administrative privileges." -ErrorAction Stop
} else {
    Write-Verbose "Running with administrative privileges."
}
#endregion

#region Validate Service Exists
Write-Verbose "Validating service '$ServiceName' exists..."
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Error "Service '$ServiceName' not found." -ErrorAction Stop
}
# Use the exact name property found by Get-Service
$ExactServiceName = $service.Name
Write-Host "Found service: $($service.DisplayName) ($ExactServiceName)"
#endregion

#region Step 1: Set Failure Flag using sc.exe failureflag
Write-Host "Step 1: Attempting to set failure flag for '$ExactServiceName' using 'sc.exe failureflag 1'..."
Write-Warning "The 'sc.exe failureflag' command is potentially undocumented or environment-specific."

$scFlagArgs = "failureflag `"$ExactServiceName`" 1"
Write-Verbose "Executing: sc.exe $scFlagArgs"

try {
    # Execute sc.exe failureflag command
    $processFlag = Start-Process sc.exe -ArgumentList $scFlagArgs -Wait -PassThru -NoNewWindow -RedirectStandardError "$PSScriptRoot\sc_flag_error.log" -ErrorAction Stop

    if ($processFlag.ExitCode -eq 0) {
       Write-Host "Successfully executed 'sc.exe failureflag 1' for '$ExactServiceName' (Exit Code 0)."
       # Clean up error log if successful
       if (Test-Path "$PSScriptRoot\sc_flag_error.log") { Remove-Item "$PSScriptRoot\sc_flag_error.log" }
    } else {
       $errorMsg = "Command 'sc.exe failureflag 1' for '$ExactServiceName' failed or returned a non-zero exit code: $($processFlag.ExitCode)."
       # Include stderr output if the log file exists
       if (Test-Path "$PSScriptRoot\sc_flag_error.log") {
           $scErrorOutput = Get-Content "$PSScriptRoot\sc_flag_error.log" -Raw
           if (-not [string]::IsNullOrWhiteSpace($scErrorOutput)) {
               $errorMsg += " SC.EXE Error Output:`n$scErrorOutput"
           }
           Remove-Item "$PSScriptRoot\sc_flag_error.log"
       }
       # Treat non-zero exit code as a potential failure, but maybe continue to setting actions? Or Stop? Let's stop for now.
       Write-Error $errorMsg -ErrorAction Stop
    }
} catch {
    Write-Error "An error occurred while executing Start-Process for 'sc.exe failureflag': $_" -ErrorAction Stop
}
#endregion

#region Step 2: Configure Specific Recovery Actions (Restart) via sc.exe failure
Write-Host "Step 2: Configuring restart actions and delays for '$ExactServiceName' using 'sc.exe failure'..."

# Construct the actions string: action1/delay1/action2/delay2/action3/delay3
$actions = "restart/$DelayMilliseconds/restart/$DelayMilliseconds/restart/$DelayMilliseconds"

# Construct the arguments for sc.exe failure
$scFailureArgs = "failure `"$ExactServiceName`" reset= $ResetPeriodSeconds actions= $actions"

Write-Verbose "Executing: sc.exe $scFailureArgs"

try {
    # Execute sc.exe failure command
    $processFailure = Start-Process sc.exe -ArgumentList $scFailureArgs -Wait -PassThru -NoNewWindow -RedirectStandardError "$PSScriptRoot\sc_failure_error.log" -ErrorAction Stop

    if ($processFailure.ExitCode -eq 0) {
       Write-Host "Successfully configured recovery actions using 'sc.exe failure' for '$ExactServiceName'."
       Write-Host "  Reset Fail Count After: $ResetPeriodSeconds seconds"
       Write-Host "  Restart Service After: $($DelayMilliseconds / 1000) seconds (for 1st, 2nd, and subsequent failures)"
       # Clean up error log if successful
       if (Test-Path "$PSScriptRoot\sc_failure_error.log") { Remove-Item "$PSScriptRoot\sc_failure_error.log" }
    } else {
       $errorMsg = "Command 'sc.exe failure' for '$ExactServiceName' failed. sc.exe exited with code $($processFailure.ExitCode)."
       # Include stderr output if the log file exists
       if (Test-Path "$PSScriptRoot\sc_failure_error.log") {
           $scErrorOutput = Get-Content "$PSScriptRoot\sc_failure_error.log" -Raw
           if (-not [string]::IsNullOrWhiteSpace($scErrorOutput)) {
               $errorMsg += " SC.EXE Error Output:`n$scErrorOutput"
           }
           Remove-Item "$PSScriptRoot\sc_failure_error.log"
       }
       Write-Error $errorMsg -ErrorAction Stop
    }

} catch {
    Write-Error "An error occurred while executing Start-Process for 'sc.exe failure': $_" -ErrorAction Stop
}
#endregion

Write-Host "Service recovery configuration complete for '$ExactServiceName'."
Write-Verbose "Script finished."
