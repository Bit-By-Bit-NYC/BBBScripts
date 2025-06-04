// Azure Function: GetRebootPatchStatus.cs
using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.WebJobs;
using Microsoft.Azure.WebJobs.Extensions.Http;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;
using Azure.Identity;
using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using System.Collections.Generic;

namespace Functions
{
    public static class GetRebootPatchStatus
    {
        [FunctionName("GetRebootPatchStatus")]
        public static async Task<IActionResult> Run(
            [HttpTrigger(AuthorizationLevel.Function, "get", Route = null)] HttpRequest req,
            ILogger log)
        {
            log.LogInformation("C# HTTP trigger function processed a request.");

            string subscriptionId = req.Query["subscriptionId"];
            string workspaceId = req.Query["workspaceId"];

            if (string.IsNullOrWhiteSpace(subscriptionId) || string.IsNullOrWhiteSpace(workspaceId))
            {
                return new BadRequestObjectResult("Please provide both 'subscriptionId' and 'workspaceId' as query parameters.");
            }

            var kqlQuery = @"
let rebootData = 
    Event
    | where EventLog == \"System\"
    | where EventID in (6005, 6006)
    | extend ComputerName = tolower(Computer)
    | summarize LastReboot = max(TimeGenerated), RebootComputer = any(Computer) by ComputerName;

let patchData = 
    Event
    | where EventLog == \"System\"
    | where EventID == 19
    | where not(RenderedDescription has \"Defender\" or RenderedDescription has \"Security Intelligence Update\" or RenderedDescription has \".NET Framework\")
    | where RenderedDescription has \"Installation Successful: Windows successfully installed the following update\" and RenderedDescription has \"Cumulative\" or RenderedDescription has \"Security\"
    | extend ComputerName = tolower(Computer)
    | summarize arg_max(TimeGenerated, RenderedDescription, Computer) by ComputerName
    | project ComputerName, LastPatchTime = TimeGenerated, PatchDetails = RenderedDescription, PatchComputer = Computer;

rebootData
| join kind=fullouter patchData on ComputerName
| project 
    Computer = coalesce(RebootComputer, PatchComputer),
    LastReboot = coalesce(LastReboot, datetime(null)),
    LastPatchTime = coalesce(LastPatchTime, datetime(null)),
    PatchDetails = coalesce(PatchDetails, \"No patch record found\")
";

            var credential = new DefaultAzureCredential();
            var logsClient = new LogsQueryClient(credential);

            try
            {
                var response = await logsClient.QueryWorkspaceAsync(
                    workspaceId,
                    kqlQuery,
                    new QueryTimeRange(TimeSpan.FromDays(30)));

                var table = response.Value.Table;
                var results = new List<object>();

                foreach (var row in table.Rows)
                {
                    var computer = row["Computer"]?.ToString();
                    var reboot = FormatDate(row["LastReboot"]);
                    var patch = FormatDate(row["LastPatchTime"]);
                    var patchDetails = row["PatchDetails"]?.ToString() ?? "N/A";

                    results.Add(new
                    {
                        Computer = computer,
                        LastReboot = reboot,
                        LastPatchTime = patch,
                        PatchDetails = patchDetails
                    });
                }

                return new JsonResult(results);
            }
            catch (Exception ex)
            {
                log.LogError(ex, "Failed to query log analytics.");
                return new StatusCodeResult(500);
            }
        }

        private static string FormatDate(object dt)
        {
            if (dt == null || string.IsNullOrEmpty(dt.ToString())) return "Missing";
            if (DateTime.TryParse(dt.ToString(), out var parsed)) return parsed.ToString("yyyy-MM-dd");
            return "Invalid";
        }
    }
}