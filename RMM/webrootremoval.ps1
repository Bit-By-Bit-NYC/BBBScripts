& 'C:\Program Files (x86)\Webroot\WRSA.exe' -uninstall
& 'C:\Program Files\Webroot\WRSA.exe' -uninstall
Get-Process | Where-Object ProcessName -Like "*webroot*" | Stop-Process -Force
sc.exe stop WRSVC
sc.exe stop WRCoreService
sc.exe stop WRSkyClient
sc.exe delete WRSVC
sc.exe delete WRCoreService
sc.exe delete WRSkyClient
Remove-Item "C:\ProgramData\WRData" -Force -Recurse
Remove-Item "C:\ProgramData\WRCore" -Force -Recurse
Remove-Item "C:\Program Files\Webroot" -Force -Recurse
Remove-Item "C:\Program Files (x86)\Webroot" -Force -Recurse
Remove-Item "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Webroot SecureAnywhere" -Force -Recurse
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\WRUNINST" -Force
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\WRUNINST" -Force
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\WRData" -Force
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\WRCore" -Force
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\WRMIDData" -Force
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\webroot" -Force
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WRUNINST" -Force
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WRUNINST" -Force
Remove-Item "HKLM:\SOFTWARE\WRData" -Force
Remove-Item "HKLM:\SOFTWARE\WRMIDData" -Force
Remove-Item "HKLM:\SOFTWARE\WRCore" -Force
Remove-Item "HKLM:\SOFTWARE\webroot" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet001\services\WRSVC" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet001\services\WRkrn" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet001\services\WRBoot" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet001\services\WRCore" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet001\services\WRCoreService" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet001\services\wrUrlFlt" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet002\services\WRSVC" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet002\services\WRkrn" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet002\services\WRBoot" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet002\services\WRCore" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet002\services\WRCoreService" -Force
Remove-Item "HKLM:\SYSTEM\ControlSet002\services\wrUrlFlt" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\services\WRSVC" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\services\WRkrn" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\services\WRBoot" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\services\WRCore" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\services\WRCoreService" -Force
Remove-Item "HKLM:\SYSTEM\CurrentControlSet\services\wrUrlFlt" -Force
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{C96F4AE6-A790-469E-8CFA-BDA1A08E3E00}" -Force
Remove-Item "HKLM:\SOFTWARE\Classes\Installer\Features\6EA4F69C097AE964C8AFDB1A0AE8E300" -Force
Remove-Item "HKLM:\SOFTWARE\Classes\Installer\Products\6EA4F69C097AE964C8AFDB1A0AE8E300" -Force
Remove-Item "HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\66F6A6E8AD294AB41B7E5A8D94B5563B" -Force
Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" -Name "WRSVC"
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "WRSVC"