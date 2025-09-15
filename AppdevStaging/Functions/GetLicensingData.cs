// File: GetLicensingData.cs
using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Azure.Identity;
using Azure.Core;
using Microsoft.Graph;
using Microsoft.Graph.Models;
using CsvHelper;

namespace AppdevStaging.Functions
{
    public static class GetLicensingData
    {
        [Function("GetLicensingData")]
        public static async Task<HttpResponseData> Run(
            [HttpTrigger(AuthorizationLevel.Anonymous, "get")] HttpRequestData req,
            FunctionContext executionContext)
        {
            var log = executionContext.GetLogger("GetLicensingData");
            log.LogInformation("📥 GetLicensingData triggered.");

            var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
            string tenantId = query["tenantId"];
            if (string.IsNullOrEmpty(tenantId))
            {
                var badResponse = req.CreateResponse(HttpStatusCode.BadRequest);
                await badResponse.WriteStringAsync("Missing tenantId in query string.");
                return badResponse;
            }

            try
            {
                var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")!;
                var clientSecret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET")!;
                var credential = new ClientSecretCredential(tenantId, clientId, clientSecret);
                var graphClient = new GraphServiceClient(credential);

                // 🔍 Build dynamic SKU map
                log.LogInformation("📦 Fetching SubscribedSkus...");
                var skuResponse = await graphClient.SubscribedSkus.GetAsync();
                var dynamicSkuMap = new Dictionary<string, string>();

                foreach (var sku in skuResponse?.Value ?? new List<SubscribedSku>())
                {
                    if (sku.SkuId != null)
                    {
                        dynamicSkuMap[sku.SkuId.ToString()] = sku.SkuPartNumber ?? $"Unmapped SKU: {sku.SkuId}";
                    }
                }

                // 👥 Get all users
                var allUsers = new List<User>();
                var page = await graphClient.Users.GetAsync(reqConf =>
                {
                    reqConf.QueryParameters.Select = new[] {
                        "displayName", "userPrincipalName", "assignedLicenses",
                        "signInActivity", "accountEnabled", "mobilePhone",
                        "businessPhones", "onPremisesSyncEnabled"
                    };
                    reqConf.QueryParameters.Top = 999;
                });

                while (page != null)
                {
                    allUsers.AddRange(page.Value);
                    if (page.OdataNextLink == null) break;
                    log.LogInformation("🔁 Fetching next page of users...");
                    page = await graphClient.Users.WithUrl(page.OdataNextLink).GetAsync();
                }

                log.LogInformation($"📊 Total users retrieved: {allUsers.Count}");

                // 📥 Fetch mailbox usage CSV
          log.LogInformation("📥 Fetching mailbox usage report...");
var csvStream = await graphClient.Reports.GetMailboxUsageDetailWithPeriod("D7").GetAsync();

var usageDict = new Dictionary<string, Dictionary<string, string>>();

try
{
    using var reader = new StreamReader(csvStream);
    using var csv = new CsvReader(reader, CultureInfo.InvariantCulture);
    var records = csv.GetRecords<dynamic>().ToList();

    log.LogInformation($"📄 Mailbox usage CSV record count: {records.Count}");

    if (records.Count > 0)
    {
        var firstRecord = (IDictionary<string, object>)records[0];
        log.LogInformation("📄 CSV headers: " + string.Join(", ", firstRecord.Keys));

        foreach (IDictionary<string, object> record in records)
        {
            if (record.TryGetValue("User Principal Name", out var upnObj) && upnObj != null)
            {
                var upn = upnObj.ToString()?.ToLower();
                if (!string.IsNullOrEmpty(upn))
                {
                    // Store all fields as strings
                    var fieldData = record.ToDictionary(
                        kv => kv.Key,
                        kv => kv.Value?.ToString() ?? ""
                    );
                    usageDict[upn] = fieldData;
                }
            }
        }

        log.LogInformation($"✅ Mailbox usage data mapped for {usageDict.Count} users.");
    }
    else
    {
        log.LogWarning("⚠ Mailbox usage CSV returned 0 records.");
    }
}
catch (Exception ex)
{
    log.LogError(ex, "❌ Error while parsing mailbox usage CSV.");
}

                // 🧩 Merge data
                var results = allUsers.Select(user => new
                {
                    user.DisplayName,
                    user.UserPrincipalName,
                    Licenses = user.AssignedLicenses?.Select(l =>
                    {
                        var id = l.SkuId?.ToString() ?? "";
                        return dynamicSkuMap.TryGetValue(id, out var name)
                            ? name : $"Unmapped SKU: {id}";
                    }).ToList() ?? new List<string> { "None" },
                    LastSignInDate = user.SignInActivity?.LastSignInDateTime,
                    SignInStatus = user.AccountEnabled == true ? "Enabled" : "Disabled",
                    MobilePhone = user.MobilePhone,
                    BusinessPhones = user.BusinessPhones != null ? string.Join(", ", user.BusinessPhones) : null,
                    IsSyncedFromAD = user.OnPremisesSyncEnabled == true ? "AD Synced" : "Cloud Only",
MailboxSizeMB = usageDict.TryGetValue(user.UserPrincipalName?.ToLower() ?? "", out var usageFields) &&
                usageFields.TryGetValue("Storage Used (Byte)", out var storageStr) &&
                long.TryParse(storageStr, out long bytesUsed)
                    ? Math.Round(bytesUsed / (1024.0 * 1024.0), 1)
                    : (double?)null
                });

                var response = req.CreateResponse(HttpStatusCode.OK);
                await response.WriteAsJsonAsync(results);
                return response;
            }
            catch (Exception ex)
            {
                log.LogError(ex, $"❌ Error retrieving licensing data for tenant {tenantId}");
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteAsJsonAsync(new
                {
                    error = "Failed to retrieve licensing data.",
                    tenantId,
                    exception = ex.Message,
                    innerException = ex.InnerException?.Message,
                    stackTrace = ex.StackTrace
                });
                return errorResponse;
            }
        }
    }
}