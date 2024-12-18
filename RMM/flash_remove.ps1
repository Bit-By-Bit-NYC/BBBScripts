param([switch]$Elevated)

function Test-Admin {
    $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
    $currentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if ((Test-Admin) -eq $false)  {
    if ($elevated) {
        # tried to elevate, did not work, aborting
    } else {
        Start-Process powershell.exe -Verb RunAs -ArgumentList ('-noprofile -file "{0}" -elevated' -f ($myinvocation.MyCommand.Definition))
    }
    exit
}

function Check_Program_Installed {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0, Mandatory=$true, ValueFromPipeline = $true)]
        $Name
    )

    $32bitApps = Get-ItemProperty -Path "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $64bitApps = Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $allApps = $64bitApps + $32bitApps

    $app = $allApps | 
                Where-Object { $_.DisplayName -match $Name } | 
                Select-Object DisplayName, DisplayVersion, InstallDate, Version
    if ($app) {
        return "True";
    }
}

$ProcName = "uninstall_flash_player.exe"
$WebFile = "http://download.macromedia.com/get/flashplayer/current/support/$ProcName"

(New-Object System.Net.WebClient).DownloadFile($WebFile,"$env:APPDATA\$ProcName")
Start-Process -FilePath "$env:APPDATA\$ProcName" -ArgumentList "-uninstall" -Wait
Remove-Item "$env:APPDATA\$ProcName"

if((Check_Program_Installed "Adobe Flash Player") -eq "True"){
    throw 'Adobe Flash Player was not correctly uninstalled!';  
}