#BOMGAR- ALL GROUP JUMP INSTALLER CREATOR
#This script will create a new installer for every jump group in the bomgar instance with max expiration date (1yr), 
#and output a list of group name, installer ids, and installer keys for mac+windows generic installers



# Define your BeyondTrust site URL, API Key (Client ID), and API Secret
# IMPORTANT: Replace these placeholder values with your actual information
# Double-check these values carefully against your BeyondTrust API Configuration.
#In our tenant, this api key is restricted by ip
$beyondTrustSiteUrl = "https://<companysubdomain>.beyondtrustcloud.com" # e.g., https://yourcompany.bomgarcloud.com
$apiKey = "<CLIENT_ID>" # Replace with your actual API Key (Client ID)
$apiSecret = "<CLIENT_SECRET>" # Replace with your actual API Secret

# --- Authentication Step ---

# Define the authentication endpoint URL
# Based on the documentation, the OAuth 2 token endpoint is typically /oauth2/token
$authUrl = "$beyondTrustSiteUrl/oauth2/token"

# Combine Client ID and Secret for Basic Authentication
# Using ${} to correctly delimit the variable names in the string
$authString = "${apiKey}:${apiSecret}"

# Base64 encode the combined string
# Using UTF8 encoding as it's standard for web communication
$authStringBytes = [System.Text.Encoding]::UTF8.GetBytes($authString)
$base64AuthString = [System.Convert]::ToBase64String($authStringBytes)

# Define the body for the authentication request
# Using the client_credentials grant type as specified in the documentation
$authBody = "grant_type=client_credentials"

# Set the headers for the authentication request
# Authorization: Basic authentication with Base64 encoded credentials
# Content-Type should be application/x-www-form-urlencoded for this grant type
# Accept: application/json to request JSON response
$authHeaders = @{
    "Authorization" = "Basic $base64AuthString" # Use Basic Authentication with Base64 encoded string
    "Content-Type"  = "application/x-www-form-urlencoded"
    "Accept"        = "application/json" # Request JSON response
}

Write-Host "Attempting to obtain access token from: $authUrl using Basic Authentication."
# Write-Host "Using Client ID: '$apiKey'" # Uncomment for debugging, but be cautious with sensitive data

try {
    # Make the POST request to the authentication endpoint
    # Use -ErrorAction Stop to ensure the catch block is triggered on non-2xx responses
    $authTokenResponse = Invoke-RestMethod -Uri $authUrl -Method Post -Headers $authHeaders -Body $authBody -UseBasicParsing -ErrorAction Stop

    # Extract the access token and token type from the response
    $accessToken = $authTokenResponse.access_token
    $tokenType = $authTokenResponse.token_type # Usually "Bearer"

    if (-not $accessToken) {
        Write-Error "Failed to obtain access token. Response did not contain 'access_token'."
        # Check for error details in the response if available
        if ($authTokenResponse.error_description) {
             Write-Error "Error Description: $($authTokenResponse.error_description)"
        } elseif ($authTokenResponse.error) {
             Write-Error "Error: $($authTokenResponse.error)"
        }
        # Attempt to output the raw response body if available, for debugging
        try {
            $rawResponse = $authTokenResponse | ConvertTo-Json -Depth 10
            Write-Host "Raw Authentication Response (if available):"
            Write-Host $rawResponse
        } catch {
            Write-Host "Could not convert authentication response to JSON for raw output."
        }

        exit 1 # Exit the script if token is not obtained
    }

    Write-Host "Successfully obtained access token."

    # --- Fetch Jump Groups ---
    # We need Jump Group IDs and Names to create installers

    $jumpGroupApiUrl = "$beyondTrustSiteUrl/api/config/v1/jump-group"

    Write-Host "Attempting to retrieve Jump Groups from: $jumpGroupApiUrl"

    # Set headers for the Jump Group listing request (using the same access token)
    $jumpGroupHeaders = @{
        "Authorization" = "$tokenType $accessToken"
        "Accept"        = "application/json"
    }

    # Fetch jump groups
    # For large numbers of groups, pagination logic would be needed here.
    $jumpGroups = Invoke-RestMethod -Uri $jumpGroupApiUrl -Method Get -Headers $jumpGroupHeaders -UseBasicParsing -ErrorAction Stop

    # Array to store details for output
    $installerDetailsOutput = @()

    if ($jumpGroups -and $jumpGroups.count -gt 0) {
        Write-Host "Successfully retrieved $($jumpGroups.count) Jump Groups. Proceeding to create installers."

        # --- Create Installers for Each Jump Group ---

        $createInstallerApiUrl = "$beyondTrustSiteUrl/api/config/v1/jump-client/installer"

        # Set headers for the installer creation request
        $createInstallerHeaders = @{
            "Authorization" = "$tokenType $accessToken"
            "Content-Type"  = "application/json" # POST requests with JSON body require this
            "Accept"        = "application/json" # Request JSON response
        }

        # Iterate through each jump group
        foreach ($jumpGroup in $jumpGroups) {
            Write-Host "`nCreating installer for Jump Group: $($jumpGroup.name) (ID: $($jumpGroup.id))"

            # Construct the JSON body for the new installer
            # Based on the curl example and OpenAPI spec
            $installerBody = @{
                customer_client_start_mode = "hidden"
                valid_duration             = 525600 # 1 year in minutes
                jump_group_id              = $jumpGroup.id
                jump_group_type            = "shared" # Assuming creating shared installers
                # Add other desired properties from the JumpClientInstaller schema here if needed
                # e.g., tag, comments, jump_policy_id, attended_session_policy_id, unattended_session_policy_id
            } | ConvertTo-Json

            try {
                # Make the POST request to create the installer
                $newInstallerResponse = Invoke-RestMethod -Uri $createInstallerApiUrl -Method Post -Headers $createInstallerHeaders -Body $installerBody -UseBasicParsing -ErrorAction Stop

                Write-Host "Installer created successfully for $($jumpGroup.name)."

                # Extract required details for output
                $installerId = $newInstallerResponse.installer_id
                $macInstallerInfo = $newInstallerResponse.key_info."mac-osx-x86"
                $win64MsiInstallerInfo = $newInstallerResponse.key_info."winNT-64-msi"

                # Add details to the output array
                $installerDetailsOutput += New-Object PSObject -Property @{
                    "Jump Group Name"   = $jumpGroup.name
                    "Installer ID"      = $installerId
                    "Mac Encoded Info"  = $macInstallerInfo.encodedInfo
                    "Win64 MSI Encoded Info" = $win64MsiInstallerInfo.encodedInfo
                }

            }
            catch {
                Write-Error "Failed to create installer for Jump Group $($jumpGroup.name) (ID: $($jumpGroup.id))."
                Write-Error $_.Exception.Message

                # Attempt to read the response body for more error details on failure
                if ($_.Exception.Response) {
                    try {
                        $responseBody = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()).ReadToEnd()
                        Write-Error "Response Body:"
                        Write-Error $responseBody
                    } catch {
                        Write-Error "Could not read the response body for more error details on installer creation failure."
                    }
                }
            }
        }

        # --- Output Collected Installer Details ---

        Write-Host "`n--- Created Installer Details ---"
        # Output the collected data
        $installerDetailsOutput | Format-List # Using Format-List for readability in console

    } else {
        Write-Host "No Jump Groups found, so no installers could be created."
    }

}
catch {
    # Handle potential errors during the initial API calls (authentication or fetching jump groups)
    Write-Host "`nAn error occurred during initial API calls:"
    # Output the specific error message from the exception
    Write-Host $_.Exception.Message

    # If the error is an HTTP error, try to get more details
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDescription = $_.Exception.Response.StatusCode
        Write-Host "HTTP Status Code: $statusCode ($statusDescription)"

        # Attempt to read the response body for more error details
        try {
            $responseBody = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()).ReadToEnd()
            Write-Host "Response Body:"
            Write-Host $responseBody
        } catch {
            Write-Host "Could not read the response body for more error details."
        }
    }

    Write-Host "`nPossible causes for initial failure (authentication or fetching jump groups):"
    Write-Host "- Incorrect site URL, API Key (Client ID), or API Secret."
    Write-Host "- API account is not active or lacks permissions for token generation or listing Jump Groups."
    Write-Host "- Incorrect API endpoint URLs."
    Write-Host "- Network connectivity issues."
}

Write-Host "Script finished."