$TPM = Get-WmiObject win32_tpm -Namespace root\cimv2\security\microsofttpm | where {$_.IsEnabled().Isenabled -eq 'True'} -ErrorAction SilentlyContinue
$WindowsVer = Get-WmiObject -Query 'select * from Win32_OperatingSystem where (Version like "6.2%" or Version like "6.3%" or Version like "10.0%") and ProductType = "1"' -ErrorAction SilentlyContinue
$BitLockerReadyDrive = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue

 
#If all of the above prequisites are met, then create the key protectors, then enable BitLocker and backup the Recovery key to AD.
if ($WindowsVer -and $TPM -and $BitLockerReadyDrive) {
 
#Creating the recovery key
Start-Process 'manage-bde.exe' -ArgumentList " -protectors -add $env:SystemDrive -recoverypassword" -Verb runas -Wait
 
#Adding TPM key
#Start-Process 'manage-bde.exe' -ArgumentList " -protectors -add $env:SystemDrive  -tpm" -Verb runas -Wait
#sleep -Seconds 15 #This is to give sufficient time for the protectors to fully take effect.
 
#Enabling Encryption
Start-Process 'manage-bde.exe' -ArgumentList " -on -usedspaceonly $env:SystemDrive -em aes256 " -Verb runas -Wait
 
#Getting Recovery Key GUID
$RecoveryKeyGUID = (Get-BitLockerVolume -MountPoint $env:SystemDrive).keyprotector | where {$_.Keyprotectortype -eq 'RecoveryPassword'} | Select-Object -ExpandProperty KeyProtectorID

#Backing Password file to the server
#manage-bde -protectors -get C: |out-file "c:\$($env:computername -replace '\D','').txt"
(Get-BitLockerVolume -MountPoint C).KeyProtector.recoverypassword –match ‘\S’  > "C:\temp\bitlocker-recovery.txt"

#remaining steps handled by kaseya: back up recovery key, force reboot
}