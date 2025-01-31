#Script for disabling all accounts in AzureAD
#Outputs a list of accounts so it can be easily restored using the last line of the script

#Pay attention to the comments. uncomment lines 15 and 16 if you want to sign out all users and lock all users respectively
#adjust line 13,14 for any exceptions needed (I.e. global admin) 
#For restoring blocked accounts, Uncomment line 23 and comment out line 10 

Install-Module AzureAD
Connect-AzureAD
$txtPath = 'C:\'
$fileName = 'DisabledAccounts.txt'
$OutputPath = $txtPath+$fileName
$Output = New-Item -Path $OutputPath -ItemType "file" 
$users = Get-AzureADUser -All $true |Where-Object {$_.AccountEnabled -eq $true}
    Foreach ($user in $users) {
        $ObjectID = $user.ObjectID
        if ($user.userPrincipalName -ne 'bbbadmin@<domain>.com') {
            if($user.userPrincipalName -ne 'noreply@<domain>.com') {
            Add-Content -Path $OutputPath -Value $user.userPrincipalName
            #Revoke-AzureADUserAllRefreshToken -ObjectID $ObjectID
            #Set-AzureADUser -ObjectID $ObjectID -AccountEnabled $false
}
}
}

#Get-Content $OutputPath | ForEach {Set-AzureADUser -ObjectID $_ -AccountEnabled $true}
