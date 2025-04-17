#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users
<#
.SYNOPSIS
Interactively resets the Microsoft Graph passwords for a predefined list of users,
generates strong passwords, and forces a password change on next sign-in using Update-MgUser.

.DESCRIPTION
This script connects to Microsoft Graph using an interactive login prompt.
It generates a unique, random, complex password for each user in the specified list,
updates their password profile in Azure AD/Microsoft Graph using the Update-MgUser cmdlet
and the -PasswordProfile parameter, and requires them to change the password upon their next login.
Results (including new passwords for successful resets) are displayed at the end.

.NOTES
Author: GregP+Gemini
Date: 2025-04-17
Version: 1.3 (Reverted to Update-MgUser -PasswordProfile due to issues with Update-MgUserPassword)

Prerequisites:
- PowerShell 5.1 or later.
- Microsoft.Graph.Authentication module installed (`Install-Module Microsoft.Graph.Authentication`).
- Microsoft.Graph.Users module installed (`Install-Module Microsoft.Graph.Users`).
- Permissions Required: User.ReadWrite.All (Delegated).
  You must sign in with an account that has this permission granted (e.g., via Global Admin role and Admin Consent).

Troubleshooting:
- If you encounter permission errors despite using a Global Admin account and granting consent,
  check Azure AD Sign-in Logs and Audit Logs for specific failure reasons and error codes (AADSTSxxxxx).
  Conditional Access policies might also be interfering.

.EXAMPLE
.\Reset-InteractiveUserPasswords.ps1
Runs the script, prompting for interactive login.
#>

#region Configuration

# Tenant domain (appended to usernames)
$TenantDomain = "[DOMAIN]"

# Required Microsoft Graph Permissions for interactive delegated access
# Reverted to User.ReadWrite.All, which is needed for Get-MgUser and Update-MgUser -PasswordProfile.
$RequiredScopes = @("User.ReadWrite.All")

# User Principal Names (UPNs) of the users to update
$UsersToUpdate = @(
    "USER@$TenantDomain",
    "USER2@$TenantDomain",
    "USER3@$TenantDomain"
    # Add more users as needed
)

# Password Complexity Requirements
$PasswordLength = 16          # Minimum password length
$PasswordRequiresLower = $true  # Require at least one lowercase letter
$PasswordRequiresUpper = $true  # Require at least one uppercase letter
$PasswordRequiresDigit = $true  # Require at least one digit
$PasswordRequiresSymbol = $true # Require at least one symbol

#endregion

#region Helper Functions

# Function to check if required modules are installed
function Test-RequiredModules {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Modules
    )
    $missingModules = @()
    foreach ($moduleName in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            $missingModules += $moduleName
        }
    }
    if ($missingModules.Count -gt 0) {
        Write-Error "Required module(s) not found: $($missingModules -join ', '). Please install them using 'Install-Module -Name <ModuleName>'."
        return $false
    }
    Write-Verbose "Required modules found: $($Modules -join ', ')"
    return $true
}

# Function to generate a random password meeting complexity requirements
function Generate-ComplexPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Length = 16,
        [Parameter(Mandatory = $true)]
        [bool]$RequireLower = $true,
        [Parameter(Mandatory = $true)]
        [bool]$RequireUpper = $true,
        [Parameter(Mandatory = $true)]
        [bool]$RequireDigit = $true,
        [Parameter(Mandatory = $true)]
        [bool]$RequireSymbol = $true
    )

    # Define character sets
    $lowerChars = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $upperChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $digitChars = '0123456789'.ToCharArray()
    # Ensure symbols used are generally accepted by Azure AD password policies
    # Hyphen '-' is at the end to avoid regex range errors if used elsewhere
    $symbolChars = '!@#$%^&*()_+=[]{}|;:,.<>/?~-'.ToCharArray()

    # Build the pool of allowed characters for filling the remainder
    $charPool = @()
    if ($RequireLower) { $charPool += $lowerChars }
    if ($RequireUpper) { $charPool += $upperChars }
    if ($RequireDigit) { $charPool += $digitChars }
    if ($RequireSymbol) { $charPool += $symbolChars }

    if ($charPool.Count -eq 0) {
        Write-Error "Password generation requires at least one character type to be enabled."
        return $null
    }

    # Guarantee inclusion of required character types first
    $passwordChars = [System.Collections.Generic.List[char]]::new()
    $requiredTypesAdded = 0

    if ($RequireLower) {
        $passwordChars.Add(($lowerChars | Get-Random))
        $requiredTypesAdded++
    }
    if ($RequireUpper) {
        $passwordChars.Add(($upperChars | Get-Random))
        $requiredTypesAdded++
    }
    if ($RequireDigit) {
        $passwordChars.Add(($digitChars | Get-Random))
        $requiredTypesAdded++
    }
    if ($RequireSymbol) {
        $passwordChars.Add(($symbolChars | Get-Random))
        $requiredTypesAdded++
    }

    # Check if length is sufficient for required characters
    if ($Length -lt $requiredTypesAdded) {
        Write-Error "Password length ($Length) is too short to include all required character types ($requiredTypesAdded required)."
        return $null
    }

    # Fill the remaining length with random characters from the combined pool
    $remainingLength = $Length - $passwordChars.Count
    for ($i = 0; $i -lt $remainingLength; $i++) {
        $passwordChars.Add(($charPool | Get-Random))
    }

    # Shuffle the generated characters thoroughly
    $shuffledPasswordChars = $passwordChars | Get-Random -Count $passwordChars.Count

    # Join the characters into the final password string
    return -join $shuffledPasswordChars
}


# Function to reset user password using Update-MgUser -PasswordProfile
function Reset-GraphUserPassword {
    [CmdletBinding(SupportsShouldProcess = $true)] # Supports -WhatIf / -Confirm
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory = $true)]
        # The plain text password generated by Generate-ComplexPassword
        [string]$PlainTextPassword
    )

    Write-Verbose "Attempting to reset password for user: $UserPrincipalName using Update-MgUser -PasswordProfile"

    try {
        # Find the user by UPN - Get the ID needed for Update-MgUser
        $user = Get-MgUser -Filter "UserPrincipalName eq '$UserPrincipalName'" -Property Id -ErrorAction Stop
        if (-not $user) {
            Write-Warning "User '$UserPrincipalName' not found."
            return $false # Indicate failure: User not found
        }

        $userId = $user.Id
        Write-Verbose "Found user '$UserPrincipalName' with ID: $userId"

        # Define the password profile payload for Update-MgUser
        # Password is plain text here. Force change on next sign-in.
        $passwordProfile = @{
            ForceChangePasswordNextSignIn = $true
            Password                      = $PlainTextPassword
        }

        # Use ShouldProcess for confirmation before making changes
        if ($PSCmdlet.ShouldProcess("User '$UserPrincipalName' (ID: $userId)", "Reset Password using Update-MgUser -PasswordProfile")) {
            # Update the user's password profile using their Object ID
            Update-MgUser -UserId $userId -PasswordProfile $passwordProfile -ErrorAction Stop
            Write-Host "Password reset initiated successfully for '$UserPrincipalName' via Update-MgUser." -ForegroundColor Green
            return $true # Indicate success
        } else {
            Write-Warning "Password reset skipped for '$UserPrincipalName' due to -WhatIf or user cancellation."
            return $false # Indicate skipped/failure
        }
    }
    catch [System.Exception] {
        # Catch any exception during the process
        Write-Warning "Failed to reset password for '$UserPrincipalName' using Update-MgUser. Error: $($_.Exception.Message)"

        # **FIX:** Robustly handle ErrorDetails, as it might not be valid JSON
        $detailedErrorMsg = ""
        if ($_.ErrorDetails) {
            try {
                $errorDetails = $_.ErrorDetails | ConvertFrom-Json -ErrorAction Stop
                $detailedErrorMsg = $errorDetails | ConvertTo-Json -Depth 3
            } catch {
                # ErrorDetails was not valid JSON, use the raw string
                $detailedErrorMsg = $_.ErrorDetails.ToString()
            }
            Write-Warning "Detailed Error Info: $detailedErrorMsg"
        } else {
             Write-Warning "Full Exception Details: $($_.Exception | Format-List | Out-String)"
        }
         Write-Warning "Error Record: $($_.Exception.ErrorRecord | Format-List | Out-String)" # Show ErrorRecord details for context
        return $false # Indicate failure
    }
}

#endregion

#region Main Script Execution

# Check if required modules are present
if (-not (Test-RequiredModules -Modules "Microsoft.Graph.Authentication", "Microsoft.Graph.Users")) {
    Write-Error "Script cannot continue until missing modules are installed."
    exit 1 # Exit script if modules are missing
}

# Connect to Microsoft Graph interactively
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Write-Host "Please login with an account having appropriate admin roles and '$($RequiredScopes -join ', ')' permissions." -ForegroundColor Yellow
try {
    # Disconnect any existing session first to ensure clean login
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    # Connect requesting the necessary scopes
    Connect-MgGraph -Scopes $RequiredScopes -ErrorAction Stop
    Write-Host "Successfully connected to Microsoft Graph." -ForegroundColor Green
    # Display context for verification
    Get-MgContext | Format-List
}
catch {
    Write-Error "Failed to connect to Microsoft Graph interactively: $($_.Exception.Message)"
    Write-Error "Please ensure the account has the required permissions/roles and try again."
    exit 1 # Exit script if connection fails
}


# Initialize results array
$results = @()

# Loop through the users and update their passwords
Write-Host "`nStarting password reset process for specified users..." -ForegroundColor Cyan
foreach ($upn in $UsersToUpdate) {
    Write-Host "Processing user: $($upn)..."

    # Generate a new password (plain text)
    $newPlainTextPassword = Generate-ComplexPassword -Length $PasswordLength -RequireLower $PasswordRequiresLower -RequireUpper $PasswordRequiresUpper -RequireDigit $PasswordRequiresDigit -RequireSymbol $PasswordRequiresSymbol

    if ([string]::IsNullOrEmpty($newPlainTextPassword)) {
        # Error message is already written by Generate-ComplexPassword if it failed
        Write-Warning "Skipping password reset for '$upn' due to password generation failure."
        $results += [pscustomobject]@{
            UserPrincipalName = $upn
            Password          = "Generation Failed"
            Status            = "Failed"
            Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
        continue # Move to the next user
    }

    # Reset the password using the dedicated function (now using Update-MgUser)
    # Add -WhatIf here to test without making changes:
    # $resetSuccess = Reset-GraphUserPassword -UserPrincipalName $upn -PlainTextPassword $newPlainTextPassword -WhatIf
    $resetSuccess = Reset-GraphUserPassword -UserPrincipalName $upn -PlainTextPassword $newPlainTextPassword

    # Record the result
    $status = if ($resetSuccess) { "Success" } else { "Failed" }
    # Only show the generated password in the results if the reset was successful
    $passwordOutput = if ($resetSuccess) { $newPlainTextPassword } else { "N/A" } # Show plain text password on success

    $results += [pscustomobject]@{
        UserPrincipalName = $upn
        Password          = $passwordOutput
        Status            = $status
        Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }

    # Optional: Add a small delay between API calls if needed (e.g., to avoid throttling)
    # Start-Sleep -Milliseconds 500
}

Write-Host "`nPassword reset process completed." -ForegroundColor Yellow

# Output the results table
if ($results.Count -gt 0) {
    Write-Host "`n--- Results ---" -ForegroundColor Yellow
    $results | Format-Table -AutoSize
} else {
    Write-Host "`nNo users were processed or specified in the list." -ForegroundColor Yellow
}

# Disconnect from Graph session
Write-Host "`nDisconnecting from Microsoft Graph..." -ForegroundColor Cyan
Disconnect-MgGraph

Write-Host "Script finished." -ForegroundColor Green

#endregion
