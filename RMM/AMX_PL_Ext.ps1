$RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist"
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force
}
 
# Setting the PrinterLogic Extension policy
New-ItemProperty -Path $RegPath -Name "1" `
    -Value "cpbdlogdokiacaifpokijfinplmdiapa;https://edge.microsoft.com/extensionwebstorebase/v1/crx" `
    -PropertyType String

$RegPath = "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist"
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force
}
 
# Setting the PrinterLogic Extension policy
New-ItemProperty -Path $RegPath -Name "1" `
    -Value "bfgjjammlemhdcocpejaompfoojnjjfn;https://clients2.google.com/service/update2/crx" `
    -PropertyType String