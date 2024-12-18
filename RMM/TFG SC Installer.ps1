$AgentURL = 'https://cfsbrands.hostedrmm.com/LabTech/Deployment.aspx?InstallerToken=77214a6d376c49c09ba64237c38f1462'
$AgentInstall  = 'C:\Temp\LTAgent.exe'
$AgentInsParam = '/q'
$logFile = 'C:\Temp\AgentInstall.log'
$TestPath = 'C:\windows\ltsvc\ltsvc.exe'

function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]$Message = ''
    )

    "[{0:MM/dd/yy HH:mm:ss}]`t[{1}\{2}]`t{3}" -f (Get-Date), $env:COMPUTERNAME, $env:USERNAME, $Message |
        Out-File $script:LogFile -Append
}

if (-not (Test-Path -Path $TestPath)) {
    try {
        Invoke-WebRequest $AgentURL -OutFile $AgentInstall
        Start-Process -FilePath $AgentInstall -ArgumentList $AgentInsParam -Wait
        Write-Log 'Completed successfully.'
    } catch {
        Write-Log ('Error has occurred: {0}' -f $_.Exception.Message)
    }
} else {
    Write-Log 'Computer already running Automate. Aborting.'
}