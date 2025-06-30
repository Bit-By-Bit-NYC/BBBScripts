// Azure Function: GetRebootPatchStatus.cs (Isolated Worker Model)
using System;
using System.Collections.Generic;
using System.Net;
using System.Threading.Tasks;
using Azure.Identity;
using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;

namespace Functions
{
    public class GetRebootPatchStatus
    {
        private readonly ILogger _logger;

        public GetRebootPatchStatus(ILoggerFactory loggerFactory)
        {
            _logger = loggerFactory.CreateLogger<GetRebootPatchStatus>();
        }

        [Function("GetRebootPatchStatus")]
        public async Task<HttpResponseData> Run(
            [HttpTrigger(AuthorizationLevel.Function, "get", Route = null)] HttpRequestData req,
            FunctionContext executionContext)
        {
            _logger.LogInformation("🟢 Function triggered at {time}", DateTime.UtcNow);

            var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
            string subscriptionId = query["subscriptionId"];
            string workspaceId = query["workspaceId"];

            _logger.LogInformation("📥 Query params - SubscriptionId: {sub}, WorkspaceId: {ws}", subscriptionId, workspaceId);

            if (string.IsNullOrWhiteSpace(subscriptionId) || string.IsNullOrWhiteSpace(workspaceId))
            {
                _logger.LogWarning("⚠️ Missing query parameters.");
                var badResponse = req.CreateResponse(HttpStatusCode.BadRequest);
                await badResponse.WriteStringAsync("Missing 'subscriptionId' or 'workspaceId' query parameters.");
                return badResponse;
            }

            var clientId = Environment.GetEnvironmentVariable("AZ_STAT_CLIENT_ID");
            var clientSecret = Environment.GetEnvironmentVariable("AZ_STAT_SECRET");
            var tenantId = Environment.GetEnvironmentVariable("AZURE_TENANT_ID");

            _logger.LogDebug("🔐 Using TenantId: {tenant}, ClientId: {client}", tenantId, clientId);

            ClientSecretCredential credential;
            try
            {
                credential = new ClientSecretCredential(tenantId, clientId, clientSecret);
                _logger.LogInformation("✅ ClientSecretCredential created.");
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "❌ Failed to create ClientSecretCredential.");
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteStringAsync("Error creating credentials.");
                return errorResponse;
            }


// 2025-06-04-JJS/GP - failing we think on following code; Check Application Insights runninb before hitting
            var logsClient = new LogsQueryClient(credential);
            var resultList = new List<object>();

            var kqlQuery = @"
let rebootData = 
    Event
    | where EventLog == ""System""
    | where EventID in (6005, 6006)
    | extend ComputerName = tolower(Computer)
    | summarize LastReboot = max(TimeGenerated), RebootComputer = any(Computer) by ComputerName;

let patchData = 
    Event
    | where EventLog == ""System""
    | where EventID == 19
    | where not(RenderedDescription has ""Defender"" or RenderedDescription has ""Security Intelligence Update"" or RenderedDescription has "".NET Framework"")
    | where RenderedDescription has ""Installation Successful: Windows successfully installed the following update"" and (RenderedDescription has ""Cumulative"" or RenderedDescription has ""Security"")
    | extend ComputerName = tolower(Computer)
    | summarize arg_max(TimeGenerated, RenderedDescription, Computer) by ComputerName
    | project ComputerName, LastPatchTime = TimeGenerated, PatchDetails = RenderedDescription, PatchComputer = Computer;

rebootData
| join kind=fullouter patchData on ComputerName
| project 
    Computer = coalesce(RebootComputer, PatchComputer),
    LastReboot = coalesce(LastReboot, datetime(null)),
    LastPatchTime = coalesce(LastPatchTime, datetime(null)),
    PatchDetails = coalesce(PatchDetails, ""No patch record found"")
";

            try
            {
                _logger.LogInformation("📤 Submitting KQL query...");
                var response = await logsClient.QueryWorkspaceAsync(
                    workspaceId,
                    kqlQuery,
                    new QueryTimeRange(TimeSpan.FromDays(30)));

                _logger.LogInformation("📥 Query result received. Rows: {count}", response.Value.Table.Rows.Count);

                var table = response.Value.Table;
                foreach (var row in table.Rows)
                {
                    resultList.Add(new
                    {
                        Computer = row["Computer"]?.ToString(),
                        LastReboot = FormatDate(row["LastReboot"]),
                        LastPatchTime = FormatDate(row["LastPatchTime"]),
                        PatchDetails = row["PatchDetails"]?.ToString()
                    });
                }

                var okResponse = req.CreateResponse(HttpStatusCode.OK);
                await okResponse.WriteAsJsonAsync(resultList);
                return okResponse;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "❌ Log Analytics query failed.");
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteStringAsync($"Error querying Log Analytics workspace: {ex.Message}");
                return errorResponse;
            }
        }

        private static string FormatDate(object dt)
        {
            return DateTime.TryParse(dt?.ToString(), out var parsed)
                ? parsed.ToString("yyyy-MM-dd")
                : "Missing";
        }
    }
}