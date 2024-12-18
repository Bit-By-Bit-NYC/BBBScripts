Stop-Service ITSPlatform
Stop-Service ITSPlatformManager
Set-Service -Name ITSPlatform -StartupType Disabled
Set-Service -Name ITSPlatformManager -StartupType Disabled
wmic product where "name like '%ITSPlatform%'" call uninstall /nointeractive
wmic product where "name like '%ScreenConnect Client%'" call uninstall /nointeractive
Remove-Item "C:\ProgramData\ScreenConnect Client*" -Force -Recurse
Stop-Service -Name "SAAZappr"
Stop-Service -Name "SAAZDPMACTL"
Stop-Service -Name "SAAZRemoteSupport"
Stop-Service -Name "SAAZScheduler"
Stop-Service -Name "SAAZServerPlus"
Stop-Service -Name "SAAZWatchDog"
Stop-Service -Name "SAAZapsc"
sc.exe delete SAAZappr
sc.exe delete SAAZDPMACTL
sc.exe delete SAAZRemoteSupport
sc.exe delete SAAZScheduler
sc.exe delete SAAZServerPlus
sc.exe delete SAAZWatchDog
sc.exe delete SAAZapsc
Remove-Item "C:\ProgramData\SAAZOD" -Force -Recurse
Remove-Item "C:\Program Files (x86)\SAAZOD" -Force -Recurse
Remove-Item "C:\Program Files (x86)\SAAZODBKP" -Force -Recurse
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\SAAZOD" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZappr" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZDPMACTL" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZRemoteSupport" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZScheduler" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZServerPlus" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZWatchDog" -Force
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest" -Name "ITSPlatformID" -Force
wmic product where "name like '%RMMAgent%'" call uninstall /nointeractive