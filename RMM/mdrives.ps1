new-psdrive -name HKU -psprovider registry -root HKEY_USERS
$regPath = "HKU:\*\network\*"
$value = Get-ItemProperty -Path $regPath | Select-Object "remotePath","pschildname"
$stripped = $value | fl remotepath,pschildname
$outputFile = "C:\kworking\mappeddrives.txt"
$stripped | out-file -filepath $outputFile
Remove-PSDrive -name HKU