$myDownloadUrl = 'https://bbbrmmscripts.blob.core.windows.net/$web/etc/clnwtrOilSurchargeAddIn.zip'
$downloadPath = "C:\temp\oilSurcharge.zip"
$unzipPath = "C:\temp\oilSurcharge\"
#cleanup
rm $downloadPath -r -force
rm $unzipPath -r -force
#download and unzip
Invoke-WebRequest $myDownloadUrl -OutFile $downloadPath
Expand-Archive -LiteralPath $downloadPath -DestinationPath $unzipPath
#copying to dynamics path
Copy-Item -Path "$unzipPath\dynamicsgpaddin\*" -Destination 'C:\Program Files (x86)\Microsoft Dynamics\GP2018\' -Recurse
rm $downloadPath -r -force
rm $unzipPath -r -force
