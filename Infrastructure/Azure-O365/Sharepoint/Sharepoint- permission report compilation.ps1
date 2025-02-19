# Executive Summary
# This script compiles all CSV files in a specified folder into a single CSV, 
# consolidating data from multiple files with identical column headers.

# Overview of Work & Deliverables
# The script takes a folder path as input. It then iterates through all CSV files within that folder.
# For each CSV, it reads the data, skipping the header row if it's not the first file being processed.
# Finally, it appends the data to a master data array.  This combined data is then exported to a new CSV file.

# Location and Resources
# The script requires PowerShell and access to the file system where the CSV files are located.
# No external modules are required.

# Risks
# - If CSV files have different column headers, the script will produce incorrect or misaligned data.  All CSVs must have the same columns in the same order.
# - Large numbers of CSV files or very large individual CSV files may impact memory usage.
# - Incorrect folder path will result in an error.

# Assumptions
# - All CSV files in the folder have the same headers: Object, Title, URL, HasUniquePermissions, Users, Type, Permissions, GrantedThrough.
# - The first row of each CSV is a header row.
# - The script assumes the CSV files are properly formatted.

# General Assumptions
# - The user running the script has appropriate permissions to read the CSV files and write to the output file location.
# - The output CSV file will be created in the same directory as the script.
# - Existing output file with the same name will be overwritten.

# Change Order Process
# Any changes to the script's functionality, such as handling different column names or adding error handling, will be considered a change request and handled accordingly.  This will involve updating the script and associated documentation.

# Script Start
$FolderPath = Read-Host -Prompt "Enter the path to the folder containing the CSV files"

# Check if the folder exists
if (!(Test-Path -Path $FolderPath -PathType Container)) {
    Write-Error "Folder '$FolderPath' not found."
    return  # Exit the script
}


$OutputFile = Join-Path -Path (Split-Path $MyInvocation.MyCommand.Definition -Parent) -ChildPath "CombinedCSV.csv"
$FirstFile = $true
$MasterData = @()

Get-ChildItem -Path $FolderPath -Filter "*.csv" | ForEach-Object {
    Write-Host "Processing file: $($_.FullName)"

    try {
      $CsvData = Import-Csv -Path $_.FullName

      if ($FirstFile) {
          # Include header row only for the first file
          $MasterData += $CsvData
          $FirstFile = $false
      } else {
          # Append data (skipping header row)
          $MasterData += $CsvData | Select-Object -Skip 1 # Skip the header row
      }

    } catch {
      Write-Error "Error processing file '$_.FullName': $($_.Exception.Message)"
      return # Exit on error to prevent corrupted output.  Consider a more robust error handling approach in production.
    }
}

# Export the combined data to a new CSV
try {
    $MasterData | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Combined data exported to: $OutputFile"
} catch {
    Write-Error "Error exporting data: $($_.Exception.Message)"
}

# Script End