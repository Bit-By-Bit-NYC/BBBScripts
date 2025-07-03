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

namespace AppdevStaging.Functions
{
    public static class GetLicensingData
    {
        [Function("GetLicensingData")]
        public static async Task<HttpResponseData> Run(
            [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequestData req,
            FunctionContext executionContext)
        {
            var log = executionContext.GetLogger("GetLicensingData");
            log.LogInformation("GetLicensingData triggered.");

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

                var credential = new ClientSecretCredential(
                    tenantId,
                    clientId,
                    clientSecret);

                var graphClient = new GraphServiceClient(credential);
                var usersResponse = await graphClient.Users
                    .GetAsync(requestConfiguration =>
                    {
                        requestConfiguration.QueryParameters.Select = new[] {
                            "displayName",
                            "userPrincipalName",
                            "assignedLicenses",
                            "signInActivity"
                        };
                    });

                var skuMap = LicenseHelper.GetSkuMap();

                var results = usersResponse?.Value?.Select(user => new
                {
                    user.DisplayName,
                    user.UserPrincipalName,
                    Licenses = user.AssignedLicenses?.Select(l =>
                        skuMap.TryGetValue(l.SkuId.ToString(), out var name) ? name : l.SkuId.ToString()) ?? new List<string> { "None" },
                    LastSignInDate = user.SignInActivity?.LastSignInDateTime
                });

                var response = req.CreateResponse(HttpStatusCode.OK);
                await response.WriteAsJsonAsync(results);
                return response;
            }
            catch (Exception ex)
            {
                log.LogError(ex, "Error retrieving licensing data.");
                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteStringAsync("Internal server error.");
                return errorResponse;
            }
        }
    }

    public static class LicenseHelper
    {
        public static Dictionary<string, string> GetSkuMap() => new Dictionary<string, string>
        {
            { "6fd2c87f-b296-42f0-b197-1e91e994b900", "Office 365 E3" },
            { "c42b9cae-ea4f-4ab7-9717-81576235ccac", "Microsoft 365 Business Basic" },
            // Add more mappings as needed
        };
    }
}
