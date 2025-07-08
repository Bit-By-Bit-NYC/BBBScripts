using System.Net;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Azure.Identity;
using Microsoft.Graph;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Linq;

namespace AppdevStaging.Functions
{
    public static class GetLicensingData
    {
        [Function("GetLicensingData")]
        public static async Task<HttpResponseData> Run(
            [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequestData req,
            FunctionContext executionContext)
        {
            var logger = executionContext.GetLogger("GetLicensingData");
            logger.LogInformation("Triggered GetLicensingData");

            var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
            string tenantId = query["tenantId"];

            if (string.IsNullOrWhiteSpace(tenantId))
            {
                var badResponse = req.CreateResponse(HttpStatusCode.BadRequest);
                await badResponse.WriteStringAsync("Missing tenantId");
                return badResponse;
            }

            try
            {
                var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
                var clientSecret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET");

                logger.LogInformation("TenantId: {tenantId}, ClientId: {clientId}, SecretLen: {len}",
                    tenantId, clientId, clientSecret?.Length ?? -1);

                var credential = new ClientSecretCredential(tenantId, clientId, clientSecret);

                var graphClient = new GraphServiceClient(credential, new[] { "https://graph.microsoft.com/.default" });

                var usersPage = await graphClient.Users
                    .GetAsync(requestConfig =>
                    {
                        requestConfig.QueryParameters.Select = new[] {
                            "displayName", "userPrincipalName", "assignedLicenses", "signInActivity"
                        };
                    });

                logger.LogInformation("Fetched {count} users", usersPage?.Value?.Count ?? 0);

                var skuMap = LicenseHelper.GetSkuMap();

                var results = usersPage?.Value?.Select(user => new
                {
                    user.DisplayName,
                    user.UserPrincipalName,
                    Licenses = user.AssignedLicenses?.Select(l =>
                        skuMap.TryGetValue(l.SkuId?.ToString() ?? "", out var name) ? name : l.SkuId?.ToString()) ?? new List<string> { "None" },
                    LastSignInDate = user.SignInActivity?.LastSignInDateTime
                });

                var response = req.CreateResponse(HttpStatusCode.OK);
                await response.WriteAsJsonAsync(results);
                return response;
            }
            catch (Exception ex)
            {
                logger.LogError("Error occurred: {Message}\n{Stack}", ex.Message, ex.StackTrace);
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteStringAsync("Internal Server Error: " + ex.Message);
                return errorResponse;
            }
        }
    }

    public static class LicenseHelper
    {
        public static Dictionary<string, string> GetSkuMap() => new()
        {
            { "6fd2c87f-b296-42f0-b197-1e91e994b900", "Office 365 E3" },
            { "c42b9cae-ea4f-4ab7-9717-81576235ccac", "Microsoft 365 Business Basic" },
            // Add more SKUs as needed
        };
    }
}
