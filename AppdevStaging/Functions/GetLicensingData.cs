using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Azure.Identity;
using Microsoft.Graph;
using System.Text.Json;

public class GetLicensingData
{
    private readonly ILogger _logger;

    public GetLicensingData(ILoggerFactory loggerFactory)
    {
        _logger = loggerFactory.CreateLogger<GetLicensingData>();
    }

    [Function("GetLicensingData")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = null)] HttpRequestData req)
    {
        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        var tenantId = query["tenantId"];

        if (string.IsNullOrEmpty(tenantId))
        {
            var badResponse = req.CreateResponse(HttpStatusCode.BadRequest);
            await badResponse.WriteStringAsync("Missing tenantId query parameter.");
            return badResponse;
        }

        _logger.LogInformation("Request received for tenant: {TenantId} from IP: {ClientIP}", tenantId, req.Headers.GetValues("X-Forwarded-For").FirstOrDefault());

        try
        {
            var credential = new ManagedIdentityCredential();
            var graphClient = new GraphServiceClient(credential,
                new[] { "https://graph.microsoft.com/.default" });

            // Force token request for tenant
            var token = await credential.GetTokenAsync(
                new Azure.Core.TokenRequestContext(
                    new[] { "https://graph.microsoft.com/.default" }),
                cancellationToken: default
            );

            // Set base URL to use the specific tenant
            graphClient.BaseUrl = $"https://graph.microsoft.com/v1.0";

            var users = await graphClient.Users
                .Request()
                .Select("displayName,userPrincipalName,assignedLicenses,signInActivity")
                .GetAsync();

            var skuMap = new Dictionary<string, string>
            {
                { "3b555118-da6a-4418-894f-7df1e2096870", "Microsoft 365 Business Standard" },
                { "c42b9cae-ea4f-4ab7-9717-81576235ccac", "Microsoft 365 E3" },
                { "6fd2c87f-b296-42f0-b197-1e91e994b900", "Office 365 E3" }
            };

            var results = users.Select(user => new
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
            _logger.LogError(ex, "Error while retrieving licensing data for tenant {TenantId}", tenantId);
            var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
            await errorResponse.WriteStringAsync($"Error: {ex.Message}");
            return errorResponse;
        }
    }
}