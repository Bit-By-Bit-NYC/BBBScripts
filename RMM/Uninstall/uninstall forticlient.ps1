$product = Get-WmiObject win32_product | where{$_.name -eq 'FortiClient VPN'}
Start-Process Msiexec.exe -Wait -ArgumentList "/x $($product.IdentifyingNumber) REBOOT=ReallySuppress /qn"