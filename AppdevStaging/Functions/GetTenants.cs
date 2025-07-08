using System;
using System.IO;
using System.Net;
using System.Text.Json;
using System.Collections.Generic;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using System.Data.SqlClient;
using Azure.Identity;
using Azure.Core;
using Microsoft.Extensions.Logging;
using System.IdentityModel.Tokens.Jwt;
using Microsoft.Graph;
using Microsoft.Graph.Models;

public class GetTenants
{
    private readonly string _connectionString;
    private readonly string _clientId;
    private readonly string _clientSecret;
    private readonly string _graphAppId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1"; // Reboot and Patch Insights App ID

    public GetTenants()
    {
        _connectionString = "Server=tcp:bbbai.database.windows.net,1433;Initial Catalog=bbbazuredb;";
        _clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
        _clientSecret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET");
    }

    [Function("GetTenants")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get")] HttpRequestData req,
        FunctionContext executionContext)
    {
        var logger = executionContext.GetLogger("GetTenants");
        logger.LogInformation("🔧 GetTenants function started.");

        var response = req.CreateResponse();

        try
        {
            // SQL access token
            var credential = new DefaultAzureCredential();
            var tokenRequestContext = new TokenRequestContext(new[] { "https://database.windows.net/.default" });
            var accessToken = await credential.GetTokenAsync(tokenRequestContext);

            logger.LogInformation("✅ SQL Token acquired");

            // SQL Connection
            using var connection = new SqlConnection(_connectionString) { AccessToken = accessToken.Token };
            await connection.OpenAsync();

            var command = connection.CreateCommand();
            command.CommandText = "SELECT TenantName, TenantId FROM Tenants WHERE IsActive = 1";

            var tenants = new List<Dictionary<string, string>>();
            using var reader = await command.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                tenants.Add(new Dictionary<string, string>
                {
                    { "TenantName", reader["TenantName"].ToString() },
                    { "TenantId", reader["TenantId"].ToString() }
                });
            }

            logger.LogInformation("📥 Retrieved {0} tenants.", tenants.Count);

            // Consent check for each tenant using ClientSecretCredential
            var enrichedTenants = new List<Dictionary<string, string>>();
            foreach (var tenant in tenants)
            {
                var tenantId = tenant["TenantId"];
                var graphCredential = new ClientSecretCredential(tenantId, _clientId, _clientSecret);
                var graphClient = new GraphServiceClient(graphCredential);

                try
                {
                    var servicePrincipals = await graphClient.ServicePrincipals
                        .GetAsync(config =>
                        {
                            config.QueryParameters.Filter = $"appId eq '{_graphAppId}'";
                            config.QueryParameters.Select = new[] { "id" };
                        });

                    var consented = servicePrincipals?.Value?.Count > 0;

                    enrichedTenants.Add(new Dictionary<string, string>
                    {
                        { "TenantId", tenantId },
                        { "TenantName", consented ? $"*{tenant["TenantName"]}" : tenant["TenantName"] }
                    });
                }
                catch (Exception e)
                {
                    logger.LogWarning("⚠️ Error checking consent for tenant {0}: {1}", tenantId, e.Message);
                    enrichedTenants.Add(tenant); // fallback to original
                }
            }

            tenants = tenants
                .OrderByDescending(t => t["TenantName"].StartsWith("*"))
                .ThenBy(t => t["TenantName"])
                .ToList();

            response.StatusCode = HttpStatusCode.OK;
            await response.WriteStringAsync(JsonSerializer.Serialize(enrichedTenants));
        }
        catch (Exception ex)
        {
            logger.LogError($"❌ Exception: {ex.Message}\n{ex.StackTrace}");
            response.StatusCode = HttpStatusCode.InternalServerError;
            await response.WriteStringAsync($"Error: {ex.Message}");
        }

        return response;
    }
}