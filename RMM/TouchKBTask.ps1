$actions = New-ScheduledTaskAction -Execute 'C:\kworking\TabKBReg.bat'
$trigger = New-ScheduledTaskTrigger -AtLogon 
$principal = New-ScheduledTaskPrincipal -UserId 'kioskUser0' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -Hidden
$task = New-ScheduledTask -Action $actions -Principal $principal -Trigger $trigger -Settings $settings

Register-ScheduledTask 'TouchKBFix' -InputObject $task