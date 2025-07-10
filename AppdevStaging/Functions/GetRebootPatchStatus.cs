using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading.Tasks;
using Azure.Identity;
using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Azure.ResourceManager;
using Azure.ResourceManager.Resources;
using Azure.ResourceManager.OperationalInsights;
using Azure.ResourceManager.OperationalInsights.Models;

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
            [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = null)] HttpRequestData req,
            FunctionContext executionContext)
        {
            _logger.LogInformation("🟢 Function triggered at {time}", DateTime.UtcNow);

            var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
            string tenantId = query["tenantId"];
            if (string.IsNullOrWhiteSpace(tenantId))
            {
                _logger.LogWarning("⚠️ Missing tenantId.");
                var badResponse = req.CreateResponse(HttpStatusCode.BadRequest);
                await badResponse.WriteStringAsync("Missing 'tenantId' query parameter.");
                return badResponse;
            }

            var clientId = Environment.GetEnvironmentVariable("AZ_STAT_CLIENT_ID");
            var clientSecret = Environment.GetEnvironmentVariable("AZ_STAT_SECRET");

            ClientSecretCredential credential;
            try
            {
                credential = new ClientSecretCredential(tenantId, clientId, clientSecret);
                _logger.LogInformation("✅ Credential created for tenant {tenantId}", tenantId);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "❌ Failed to create credential.");
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteStringAsync("Error creating credentials.");
                return errorResponse;
            }

            var logsClient = new LogsQueryClient(credential);
            var resultList = new List<object>();

            string kqlQuery = @"
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
    | where RenderedDescription has ""Installation Successful: Windows successfully installed the following update"" 
        and (RenderedDescription has ""Cumulative"" or RenderedDescription has ""Security"")
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
                var armClient = new ArmClient(credential, default, new ArmClientOptions());
                _logger.LogInformation("🌐 Initialized ARM client.");

                var subs = armClient.GetSubscriptions();
                await foreach (var sub in subs)
                {
                    _logger.LogInformation("📦 Checking subscription: {sub}", sub.Data.SubscriptionId);

                    var resourceGroups = sub.GetResourceGroups();
                    await foreach (var rg in resourceGroups)
                    {
                        var workspaces = rg.GetOperationalInsightsWorkspaces();
                        await foreach (var ws in workspaces)
                        {
                            _logger.LogInformation("📊 Querying workspace: {ws}", ws.Data.Name);

                            try
                            {
                                var response = await logsClient.QueryWorkspaceAsync(
                                    ws.Data.CustomerId.ToString(),
                                    kqlQuery,
                                    new QueryTimeRange(TimeSpan.FromDays(30)));

                                _logger.LogInformation("✅ Got {count} rows from workspace {ws}", response.Value.Table.Rows.Count, ws.Data.Name);

                                foreach (var row in response.Value.Table.Rows)
                                {
                                    resultList.Add(new
                                    {
                                        Computer = row["Computer"]?.ToString(),
                                        LastReboot = FormatDate(row["LastReboot"]),
                                        LastPatchTime = FormatDate(row["LastPatchTime"]),
                                        PatchDetails = row["PatchDetails"]?.ToString(),
                                        Workspace = ws.Data.Name,
                                        Subscription = sub.Data.DisplayName
                                    });
                                }
                            }
                            catch (Exception ex)
                            {
                                _logger.LogWarning(ex, "⚠️ Query failed for workspace {ws}", ws.Data.Name);
                            }
                        }
                    }
                }

                var okResponse = req.CreateResponse(HttpStatusCode.OK);
                await okResponse.WriteAsJsonAsync(resultList);
                return okResponse;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "❌ Outer failure during query orchestration.");
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteStringAsync($"Outer failure: {ex.Message}");
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