# -----------------------------------------------------------------------------
# PowerShell Function: Disable-UserAndCleanup
# -----------------------------------------------------------------------------
# This function automates the process of disabling user accounts from a csv and performing
# common cleanup tasks using Microsoft Graph and Exchange Online PowerShell.
#
#Steps: 
#1. disable login
#2. Convert mailbox to shared
#3. Remove from all groups
#4. removes all licenses
#
# Prerequisite Modules:
# - Microsoft.Graph
# - ExchangeOnlineManagement
#
# To install the required modules, run the following command in an elevated
# PowerShell session:
# Install-Module -Name Microsoft.Graph, ExchangeOnlineManagement -Force -Confirm:$false
#
# Running Instructions:
# 1. Open a PowerShell window.
# 2. Dot-source the script to load the function into your session:
#    . C:\path\to\your_script_file.ps1
# 3. Call the function with the path to your CSV file:
#    Disable-UserAndCleanup -CSVPath "C:\path\to\your_file.csv"
#    (If your CSV column header is not 'UserPrincipalName', specify it with -CsvColumnHeader)
# -----------------------------------------------------------------------------

function Disable-UserAndCleanup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "The path to a CSV file containing a list of User Principal Names.")]
        [string]$CSVPath,
        [Parameter(Mandatory = $false, HelpMessage = "The name of the column containing the User Principal Names. Defaults to 'UserPrincipalName'.")]
        [string]$CsvColumnHeader = 'UserPrincipalName'
    )

    Write-Host "Starting cleanup process for users in CSV file: $CSVPath" -ForegroundColor Yellow

    try {
        # ---------------------------------------------------------------------
        # Connect to necessary services with interactive prompts.
        # This will open a standard login window for each service.
        # ---------------------------------------------------------------------
        Write-Host "--> A connection window will open. Please sign in to Microsoft Graph." -ForegroundColor Cyan
        try {
            # Connect to Graph with the necessary scopes for user, group, and license management.
            Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All", "Directory.ReadWrite.All", "Group.Read.All", "Group.ReadWrite.All"
            Write-Host "✅ Successfully connected to Microsoft Graph." -ForegroundColor Green
        } catch {
            Write-Host "Error connecting to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
            return
        }

        Write-Host "--> A connection window will open. Please sign in to Exchange Online." -ForegroundColor Cyan
        try {
            Connect-ExchangeOnline
            Write-Host "✅ Successfully connected to Exchange Online." -ForegroundColor Green
        } catch {
            Write-Host "Error connecting to Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
            return
        }

        # ---------------------------------------------------------------------
        # Import the CSV file and get all users to process.
        # ---------------------------------------------------------------------
        Write-Host "--> Importing users from CSV..." -ForegroundColor Cyan
        $usersToProcess = @()
        $csvUsers = Import-Csv -Path $CSVPath -ErrorAction Stop

        if (-not $csvUsers) {
            Write-Host "Error: The CSV file is empty or could not be read." -ForegroundColor Red
            return
        }

        # Check if the specified column header exists in the CSV
        if (-not $csvUsers[0].PSObject.Properties.Name.Contains($CsvColumnHeader)) {
            Write-Host "Error: The CSV file does not contain a column named '$CsvColumnHeader'." -ForegroundColor Red
            Write-Host "Please check the column header in your CSV file and specify it using the -CsvColumnHeader parameter if it's different." -ForegroundColor Yellow
            Write-Host "Available columns: $($csvUsers[0].PSObject.Properties.Name -join ', ')" -ForegroundColor Cyan
            return
        }
        
        foreach ($userCsv in $csvUsers) {
            $UserPrincipalName = $userCsv.$CsvColumnHeader
            $user = Get-MgUser -UserId $UserPrincipalName -ErrorAction SilentlyContinue
            if ($user) {
                $usersToProcess += $user
            } else {
                Write-Host "Error: User with UPN '$UserPrincipalName' not found. Skipping." -ForegroundColor Red
            }
        }
        
        if ($usersToProcess.Count -eq 0) {
            Write-Host "No valid users found in the CSV file to process. Exiting." -ForegroundColor Yellow
            return
        }
        
        # ---------------------------------------------------------------------
        # Step 1: Block sign-in for all users
        # ---------------------------------------------------------------------
        Write-Host "`n--- Step 1: Blocking sign-in for all users ---" -ForegroundColor Yellow
        foreach ($user in $usersToProcess) {
            Write-Host "--> Disabling account: $($user.UserPrincipalName)"
            Set-MgUser -UserId $user.Id -AccountEnabled:$false -ErrorAction Stop
            Write-Host "✅ Account $($user.UserPrincipalName) is now disabled." -ForegroundColor Green
        }

        # ---------------------------------------------------------------------
        # Step 2: Convert all mailboxes to shared mailboxes
        # ---------------------------------------------------------------------
        Write-Host "`n--- Step 2: Converting all mailboxes to shared mailboxes ---" -ForegroundColor Yellow
        foreach ($user in $usersToProcess) {
            Write-Host "--> Attempting to convert mailbox for: $($user.UserPrincipalName)"
            try {
                Set-Mailbox -Identity $user.UserPrincipalName -Type Shared -ErrorAction Stop
                Write-Host "✅ Mailbox for $($user.UserPrincipalName) successfully converted to a shared mailbox." -ForegroundColor Green
            }
            catch {
                Write-Host "⚠️ Could not convert mailbox for $($user.UserPrincipalName). This may be because the user does not have a mailbox or the operation failed." -ForegroundColor Yellow
                Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # ---------------------------------------------------------------------
        # Step 3: Remove all users from all groups
        # ---------------------------------------------------------------------
        Write-Host "`n--- Step 3: Removing all users from all groups ---" -ForegroundColor Yellow
        foreach ($user in $usersToProcess) {
            Write-Host "--> Removing $($user.UserPrincipalName) from groups..."
            $groups = Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction Stop
            if ($groups.Count -gt 0) {
                foreach ($group in $groups) {
                    try {
                        if ($group.DisplayName -ne 'All Users' -and $group.ObjectType -eq 'Group') {
                            Write-Host "    - Removing from group: $($group.DisplayName)"
                            Remove-MgGroupMemberByRef -GroupId $group.Id -UserId $user.Id -ErrorAction Stop
                        } else {
                            Write-Host "    - Skipping removal from group: $($group.DisplayName)" -ForegroundColor Cyan
                        }
                    } catch {
                        Write-Host "⚠️ Error removing $($user.UserPrincipalName) from group $($group.DisplayName). Skipping this group." -ForegroundColor Yellow
                        Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
                Write-Host "✅ User $($user.UserPrincipalName) has been removed from all eligible groups." -ForegroundColor Green
            } else {
                Write-Host "ℹ️ User $($user.UserPrincipalName) is not a member of any groups." -ForegroundColor Cyan
            }
        }
        
        # ---------------------------------------------------------------------
        # Step 4: Remove all licenses from all users
        # ---------------------------------------------------------------------
        Write-Host "`n--- Step 4: Removing all licenses from all users ---" -ForegroundColor Yellow
        foreach ($user in $usersToProcess) {
            Write-Host "--> Removing all licenses from: $($user.UserPrincipalName)"
            $assignedLicenses = Get-MgUserLicenseDetail -UserId $user.Id -ErrorAction SilentlyContinue
            if ($assignedLicenses.Count -gt 0) {
                Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $assignedLicenses.SkuId -ErrorAction Stop
                Write-Host "✅ All licenses for $($user.UserPrincipalName) have been removed." -ForegroundColor Green
            } else {
                Write-Host "ℹ️ User $($user.UserPrincipalName) has no licenses to remove." -ForegroundColor Cyan
            }
        }

        Write-Host "`nCleanup process completed successfully for all users in the CSV." -ForegroundColor Green
    } catch {
        Write-Host "An unexpected error occurred during the process." -ForegroundColor Red
        Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Write-Host "`nDisconnecting from all services."
        Disconnect-MgGraph
        Disconnect-ExchangeOnline
    }
}
