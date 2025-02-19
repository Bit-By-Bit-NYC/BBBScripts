#Parameters
$TenantAdminURL="https://<tenant>-admin.sharepoint.com"
$UserAccount = "admin@<tenant>.com"
 
#Get Credentials to Connect
$Cred = Get-Credential
 
Try {
    #Connect to Tenant Admin
    Connect-PnPOnline -Url $TenantAdminURL -Credentials $Cred
 
    #Get All Site collections - Exclude: Seach Center, Mysite Host, App Catalog, Content Type Hub, eDiscovery and Bot Sites
    $Sites = Get-PnPTenantSite | Where -Property Template -NotIn ("SRCHCEN#0", "REDIRECTSITE#0","SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1")
         
    #Loop through each Site Collection
    ForEach ($Site in $Sites)
    {
        Try {
            #Connect to the Site
            Connect-PnPOnline -Url $Site.Url -Credentials $Cred
 
            #Get the associated Members Group of the site
            $MembersGroup = Get-PnPGroup -AssociatedMemberGroup
  
            #sharepoint online pnp powershell to add user to group
            Add-PnPGroupMember -LoginName $UserAccount -Identity $MembersGroup
	    #Permission Level to Grant
	    $PermissionLevel = "Contribute"
 	    #grant permission Level to the user
	    Set-PnPWebPermission -User $UserAccount -AddRole $PermissionLevel
            Write-host "Added User to the site:"$Site.URL -f Green
        }
        Catch {
            write-host -f Red "Error Adding User to the Site: $($Site.URL)" $_.Exception.Message
        }
    }
}
Catch {
    write-host -f Red "Error:" $_.Exception.Message
}