$avinfo = Get-CimInstance -Namespace root/SecurityCenter2 -Classname AntiVirusProduct

if ($avinfo.displayName -like '*Sentinel*') {
    $s1 = "Detected"
}
else {
    $s1 = "Not Detected"
}

$avhash = @{"Sentinel One" = $s1}

return $avhash | ConvertTo-Json -Compress