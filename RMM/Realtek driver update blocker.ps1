# Function to get Hardware IDs of Realtek cameras
function Get-RealtekCameraHardwareIDs {
    $RealtekCameraHardwareIDs = @()

    # Get all camera devices
    $CameraDevices = Get-PnpDevice -Class Camera

    foreach ($Device in $CameraDevices) {
        # Get device instance ID
        $InstanceId = $Device.InstanceId

        # Get device properties using Get-PnpDeviceProperty
        $HardwareIDs = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_HardwareIds

        #Check if the HardwareID contains VEN_10EC which is Realtek's Vendor ID
        if ($HardwareIDs -match "VEN_10EC"){
            # Add Hardware IDs to the array
            $RealtekCameraHardwareIDs += $HardwareIDs
        }
    }

    return $RealtekCameraHardwareIDs
}

# Get Realtek camera Hardware IDs
$HardwareIDs = Get-RealtekCameraHardwareIDs

if ($HardwareIDs) {
    Write-Host "Found Realtek camera(s) with the following Hardware IDs:"
    $HardwareIDs | ForEach-Object { Write-Host $_ }

    # --- Block the drivers using the registry method (as before) ---
    # Set the DenyDeviceIDs value
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" -Name "DenyDeviceIDs" -Value 1 -Force

    # Create the DenyDeviceIDs key if it doesn't exist
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs" -ItemType Key -Force
    }

    # Add the Hardware IDs as string values under the DenyDeviceIDs key
    for ($i = 0; $i -lt $HardwareIDs.Count; $i++) {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs" -Name ($i + 1).ToString() -Value $HardwareIDs[$i] -Force
    }

    Write-Host "Realtek camera driver installation blocked via Registry using detected IDs."

} else {
    Write-Host "No Realtek camera devices found."
}

# --- Example of running PnPUtil block if you have the INF file path (less necessary now) ---
#If you still have the INF file path, you can use this as well
# $InfFileName = "path\to\your\driver.inf"
# if ($InfFileName) {
#     if (!(Get-Command PnPUtil)) {
#         Write-Error "PnPUtil is not available."
#     } else {
#         try {
#             Start-Process -FilePath "PnPUtil.exe" -ArgumentList "/blockinf $InfFileName" -Verb RunAs -Wait
#             Write-Host "Realtek camera driver installation blocked using PnPUtil."
#         } catch {
#             Write-Error "Failed to block driver using PnPUtil: $_"
#         }
#     }
# }