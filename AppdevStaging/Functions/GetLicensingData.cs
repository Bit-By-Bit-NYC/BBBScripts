using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Azure.Identity;
using Microsoft.Graph;

public class GetLicensingData
{
    private readonly ILogger _logger;

    public GetLicensingData(ILoggerFactory loggerFactory)
    {
        _logger = loggerFactory.CreateLogger<GetLicensingData>();
    }

    [Function("GetLicensingData")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequestData req)
    {
        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        var tenantId = query["tenantId"];

        if (string.IsNullOrWhiteSpace(tenantId))
        {
            var badResponse = req.CreateResponse(HttpStatusCode.BadRequest);
            await badResponse.WriteStringAsync("Missing tenantId query parameter.");
            return badResponse;
        }

        _logger.LogInformation("Processing request for tenant: {TenantId}", tenantId);

        try
        {
            var credential = new ManagedIdentityCredential();
            var graphClient = new GraphServiceClient(credential, new[] { "https://graph.microsoft.com/.default" });

            // ✅ THIS IS THE MISSING LINE
            var usersResponse = await graphClient.Users
                .GetAsync(config =>
                {
                    config.QueryParameters.Select = new[] {
                        "displayName",
                        "userPrincipalName",
                        "assignedLicenses",
                        "signInActivity"
                    };
                });

            var skuMap = new Dictionary<string, string>
            {
                { "3b555118-da6a-4418-894f-7df1e2096870", "Microsoft 365 Business Standard" },
                { "c42b9cae-ea4f-4ab7-9717-81576235ccac", "Microsoft 365 E3" },
                { "6fd2c87f-b296-42f0-b197-1e91e994b900", "Office 365 E3" }
                // Expand as needed
            };

            var results = usersResponse?.Value?.Select(user => new
            {
                DisplayName = user.DisplayName,
                UserPrincipalName = user.UserPrincipalName,
                Licenses = user.AssignedLicenses?.Select(l =>
                    skuMap.ContainsKey(l.SkuId.ToString()) ? skuMap[l.SkuId.ToString()] : l.SkuId.ToString()) ?? new List<string> { "None" },
                LastSignInDate = user.SignInActivity?.LastSignInDateTime
            });

            var response = req.CreateResponse(HttpStatusCode.OK);
            await response.WriteAsJsonAsync(results);
            return response;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving data for tenant: {TenantId}", tenantId);
            var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
            await errorResponse.WriteStringAsync($"Internal error: {ex.Message}");
            return errorResponse;
        }
    }
}
