$product = Get-WmiObject win32_product | where{$_.name -eq 'Bluebeam Revu x64 21'}
Start-Process Msiexec.exe -Wait -ArgumentList "/x $($product.IdentifyingNumber) REBOOT=ReallySuppress /qn"