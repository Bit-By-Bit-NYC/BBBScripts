#Parameters
$ReportOutput = "C:\Temp\TenantSharedLinks.csv"
$ListName = "yourlibrary" # Specify your library name

$TenantAdminURL = "https://<tenantID>-admin.SharePoint.com"
$clientID = <enterprise app clientID>
$clientSecret = <enterprise app client secret>


#Connect to PnP Online (Tenant Admin)
Connect-PnPOnline -Url $TenantAdminURL -ClientId $clientID -ClientSecret $clientSecret

#Get all site collections in the tenant
$SiteCollections = Get-PnPTenantSite



$AllResults = @()

#Iterate through each site collection
ForEach ($SiteCollection in $SiteCollections) {
    try {
        Write-Host "Processing site: $($SiteCollection.Url)"
        #Connect to each site collection
        Connect-PnPOnline -Url $SiteCollection.Url -ClientId $clientID -ClientSecret $clientSecret -ErrorAction Stop
        $Ctx = Get-PnPContext

        #Get all lists in the site
        $Lists = Get-PnPList -Includes RootFolder

        #Iterate through each list
        ForEach ($List in $Lists) {
            #check if list is a document library.
            if ($List.BaseTemplate -eq 101) {

            try{
                Write-Host "Processing list: $($List.Title) in $($SiteCollection.Url)"
                #Get all list items in batches
                $ListItems = Get-PnPListItem -List $List.Id 
                #-PageSize 2000 -ErrorAction Stop
                $ItemCount = $ListItems.Count

                $global:counter = 0

                #Iterate through each list item
                ForEach ($Item in $ListItems) {
                    Write-host "Processing $item"
                    Write-Progress -PercentComplete ($global:Counter / ($ItemCount) * 100) -Activity "Getting Shared Links from '$($Item.FieldValues["FileRef"])' in $($SiteCollection.Url)/$($List.RootFolder.ServerRelativeUrl)" -Status "Processing Items $global:Counter to $($ItemCount)";

                    #Check if the Item has unique permissions
                    $HasUniquePermissions = Get-PnPProperty -ClientObject $Item -Property "HasUniqueRoleAssignments"
                    If ($HasUniquePermissions) {
                        #Get Shared Links
                        $SharingInfo = [Microsoft.SharePoint.Client.ObjectSharingInformation]::GetObjectSharingInformation($Ctx, $Item, $false, $false, $false, $true, $true, $true, $true)
                        $ctx.Load($SharingInfo)
                        $ctx.ExecuteQuery()

                        ForEach ($ShareLink in $SharingInfo.SharingLinks) {
                            If ($ShareLink.Url) {
                                If ($ShareLink.IsEditLink) {
                                    $AccessType = "Edit"
                                } elseif ($shareLink.IsReviewLink) {
                                    $AccessType = "Review"
                                } else {
                                    $AccessType = "ViewOnly"
                                }

                                #Collect the data
                                $AllResults += New-Object PSObject -property $([ordered]@{
                                    SiteURL = $SiteCollection.Url
                                    List = $List.Title
                                    Name = $Item.FieldValues["FileLeafRef"]
                                    RelativeURL = $Item.FieldValues["FileRef"]
                                    FileType = $Item.FieldValues["File_x0020_Type"]
                                    ShareLink = $ShareLink.Url
                                    ShareLinkAccess = $AccessType
                                    ShareLinkType = $ShareLink.LinkKind
                                    AllowsAnonymousAccess = $ShareLink.AllowsAnonymousAccess
                                    IsActive = $ShareLink.IsActive
                                    Expiration = $ShareLink.Expiration
                                })
                            }
                        }
                    }
                    $global:counter++
                }
            }
            catch{
                Write-Warning "Error processing list $($list.Title) within site $($SiteCollection.Url) : $($_.Exception.Message)"
            }
        }
    }
    }
    catch {
        Write-Warning "Error processing site $($SiteCollection.Url): $($_.Exception.Message)"
    }
}

$AllResults | Export-CSV $ReportOutput -NoTypeInformation
Write-host -f Green "Sharing Links Report Generated Successfully!"