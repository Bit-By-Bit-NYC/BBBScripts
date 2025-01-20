
#Uninstall ShadowSpear
$key = <SANITIZED>
$md5Password = <SANITIZED>


$keyOrig = Get-ItemPropertyValue -path 'HKLM:\SOFTWARE\WOW6432Node\SpearTip, LLC\{E364CDEE-D3A3-4FAE-8BD7-2BD0B05B9B25}' -Name 'UNINSTALL_KEY'
$keyNew = $keyOrig -replace '\s',''
Set-ItemProperty -path 'HKLM:\SOFTWARE\WOW6432Node\SpearTip, LLC\{E364CDEE-D3A3-4FAE-8BD7-2BD0B05B9B25}' -Name 'UNINSTALL_KEY' -Value $keyNew

Write-Output "Registry key has been set successfully."

Start-Sleep -Seconds 10

# Query uninstall information from the registry
$installedPrograms = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' |
                     Get-ItemProperty |
                     Where-Object { $_.DisplayName -eq "ShadowSpear Platform" }

# If found, check its version
if ($installedPrograms) {
    $version = $installedPrograms.DisplayVersion

    switch ($version) {

         "5.0.8" {
            $command = "msiexec /x '{F5260251-A092-47BF-88C2-D8B375E9486B}' /qn uninstall_key='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
        }

         "5.0.9" {
            $command = "msiexec /x '{162336DF-47BF-47DE-9E00-34D9B48939FD}' /qn uninstall_key='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
        }

         "5.1.4" {
            $command = "msiexec /x '{2B54E656-5779-46C6-847A-7E98600EDA56}' /qn uninstall_token='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
        }

        "5.2.1" {
            $command = "msiexec /x '{4DE3BFFB-A6C0-4513-9266-38D6270ED7AD}' /qn uninstall_token='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
        }

        "5.3.1" {
            $command = "msiexec /x '{86DEC2AE-DBD4-4D3E-8B8D-D003C5F5C07A}' /qn INPUT_TOKEN='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
        }
        "5.3.2" {
            $command = "msiexec /x '{86DEC2AE-DBD4-4D3E-8B8D-D003C5F5C07A}' /qn INPUT_TOKEN='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
        }
        "5.3.3" {
            $command = "msiexec /x '{0F79D3BB-BEA9-47E9-9337-063065994299}' /qn INPUT_TOKEN='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
        }
        
        # Non-production

         "5.6.0" {
            $command = "msiexec /x '{E67B631-4CEE-406E-9E4D-C5183987A32E}' /qn uninstall_key='$key'"
            Invoke-Expression -Command $command
            Write-Output "ShadowSpear $version uninstalled."
         }

        default {
            Write-Output "Version $version of ShadowSpear Platform is not handled by this script."
        }
    }
} else {
    Write-Output "ShadowSpear Platform is not installed on this computer."
}

# Check for ShadowSpear Neutralize and uninstall
$neutralizePath = "C:\Program Files\SpearTip, LLC\EndpointSetupInformation"
if (Test-Path $neutralizePath) {
    $uninstallPath = (Get-ChildItem -Path $neutralizePath -Filter installer.exe -Recurse).DirectoryName
    $pathToInstaller = "$uninstallPath\installer.exe"
    $args = @("/remove", "/silent")
    if ($md5Password) { $args += "passmd5=$md5Password" }
    Start-Process -FilePath $pathToInstaller -ArgumentList $args -Wait -WindowStyle Hidden
    Write-Output "ShadowSpear Neutralize uninstalled."
} else {
    Write-Output "ShadowSpear Neutralize is not installed on this computer."
}