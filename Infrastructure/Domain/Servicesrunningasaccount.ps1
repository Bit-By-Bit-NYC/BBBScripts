$Domain = "WORKGROUP" 
$AdminAccount = "$Domain\Administrator"

# Get all servers in the domain (filter by operating system)
$Servers = Get-ADComputer -Filter "OperatingSystem -like '*Server*'"

# Create the output CSV file with a timestamp
$Timestamp = Get-Date -Format "yyyyMMddHHmmss"
$CsvFilePath = "C:\Adminservices$Timestamp.csv"

# Create an empty array to store the results
$Results = @()

# Loop through each server
foreach ($Server in $Servers) {
  try {
    # Get all services on the server
    $Services = Get-WmiObject Win32_Service -ComputerName $Server.Name -ErrorAction Stop

    # Filter services running as the domain administrator account
    $AdminServices = $Services | Where-Object { $_.StartName -eq $AdminAccount }

    # Output to console and add to results array
    if ($AdminServices) {
      Write-Host "Services running as '$AdminAccount' on '$($Server.Name)':"
      $AdminServices | Select-Object Name, DisplayName, State, StartMode | Out-Host 
      foreach ($Service in $AdminServices) {
        $Results += [PSCustomObject]@{
          ServerName   = $Server.Name
          ServiceName  = $Service.Name
          DisplayName  = $Service.DisplayName
          State        = $Service.State
          StartMode    = $Service.StartMode
        }
      }
    }
  }
  catch {
    Write-Warning "Error accessing services on '$($Server.Name)': $_"
  }
}

# Export the results to the CSV file
$Results | Export-Csv -Path $CsvFilePath -NoTypeInformation