<#	
	.NOTES
	===========================================================================
	 Created with: 	SAPIEN Technologies, Inc., PowerShell Studio 2021 v5.8.183
	 Created on:   	7/26/2022 11:25
	 Created by:   	tectonic
	 Organization: 	
	 Filename:     	
	===========================================================================
	.DESCRIPTION
		Will query machine where this is run from and export the patch history to *.CSV.
#>



$Session = New-Object -ComObject "Microsoft.Update.Session"
$Searcher = $Session.CreateUpdateSearcher()
$historyCount = $Searcher.GetTotalHistoryCount(); $Searcher.QueryHistory(0, $historyCount) | Select-Object Date, @{
	name	   = "Operation"
	expression = { switch ($_.operation) { 1 { "Installation" }; 2 { "Uninstallation" }; 3 { "Other" } } }
}, @{
	name	   = "Status"
	expression = { switch ($_.resultcode) { 1 { "In Progress" }; 2 { "Succeeded" }; 3 { "Succeeded With Errors" }; 4 { "Failed" }; 5 { "Aborted" } } }
}, Title, Description | Export-Csv "c:\kworking\WindowsUpdates.csv" -NoTypeInformation 