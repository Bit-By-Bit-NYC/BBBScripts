// File: GetLicensingData.cs
using System;
using System.Linq;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Azure.Identity;
using Azure.Core;
using Microsoft.Graph;
using Microsoft.Graph.Models;

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
                log.LogInformation("📦 Fetching SubscribedSkus for SKU mapping...");
                var skuResponse = await graphClient.SubscribedSkus.GetAsync();
                var dynamicSkuMap = new Dictionary<string, string>();

                foreach (var sku in skuResponse?.Value ?? new List<SubscribedSku>())
                {
                    if (sku.SkuId != null)
                    {
                        dynamicSkuMap[sku.SkuId.ToString()] = sku.SkuPartNumber ?? $"Unmapped SKU: {sku.SkuId}";
                        log.LogInformation($"✅ Mapped SKU: {sku.SkuId} -> {dynamicSkuMap[sku.SkuId.ToString()]}");
                    }
                }

                // 👥 Get all users with paging
                var allUsers = new List<User>();
                var page = await graphClient.Users.GetAsync(reqConf =>
                {
                    reqConf.QueryParameters.Select = new[] {
                        "displayName",
                        "userPrincipalName",
                        "assignedLicenses",
                        "signInActivity"
                    };
                    reqConf.QueryParameters.Top = 999;
                });

                while (page != null)
                {
                    allUsers.AddRange(page.Value);
                    if (page.OdataNextLink == null) break;

                    log.LogInformation($"🔁 Fetching next page of users...");
                    page = await graphClient.Users.WithUrl(page.OdataNextLink).GetAsync();
                }

                log.LogInformation($"📊 Total users retrieved: {allUsers.Count}");

                var results = allUsers.Select(user => new
                {
                    user.DisplayName,
                    user.UserPrincipalName,
                    Licenses = user.AssignedLicenses?.Select(l =>
                    {
                        var id = l.SkuId?.ToString() ?? "";
                        var name = dynamicSkuMap.TryGetValue(id, out var skuName)
                            ? skuName
                            : $"Unmapped SKU: {id}";

                        if (!dynamicSkuMap.ContainsKey(id))
                            log.LogWarning($"⚠ Unmapped SKU GUID: {id}");

                        return name;
                    }).ToList() ?? new List<string> { "None" },

                    LastSignInDate = user.SignInActivity?.LastSignInDateTime
                });

                var response = req.CreateResponse(HttpStatusCode.OK);
                await response.WriteAsJsonAsync(results);
                return response;
            }
            catch (Exception ex)
            {
                log.LogError(ex, "❌ Error retrieving licensing data.");
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteStringAsync("Internal server error.");
                return errorResponse;
            }
        }
    }
}