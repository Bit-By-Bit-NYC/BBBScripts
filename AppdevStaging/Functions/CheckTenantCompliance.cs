using System;
using System.Net;
using System.Threading.Tasks;
using System.Collections.Generic;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Microsoft.Data.SqlClient;
using Azure.Identity;
using Azure.Core;
using Microsoft.Graph;

public class CheckTenantCompliance
{
    private readonly string _connectionString;
    private readonly string _clientId;
    private readonly string _clientSecret;
    private readonly string _graphAppId = "7f6d81f7-cbca-400b-95a8-350f8d4a34a1";
    private readonly string _backupAppId;
    private readonly string _backupAppSecret;

    public CheckTenantCompliance()
    {
        _connectionString = "Server=tcp:bbbai.database.windows.net,1433;Initial Catalog=bbbazuredb;";
        _clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
        _clientSecret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET");
        _backupAppId = Environment.GetEnvironmentVariable("backup_appid");
        _backupAppSecret = Environment.GetEnvironmentVariable("backup_appid_secret");
    }

    [Function("CheckTenantCompliance")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post")] HttpRequestData req,
        FunctionContext executionContext)
    {
        var logger = executionContext.GetLogger("CheckTenantCompliance");
        var response = req.CreateResponse();

        try
        {
            var credential = new DefaultAzureCredential();
            var tokenRequestContext = new TokenRequestContext(new[] { "https://database.windows.net/.default" });
            var accessToken = await credential.GetTokenAsync(tokenRequestContext);

            var tenantRecords = new List<(string TenantId, string TenantName)>();

            using (var connection = new SqlConnection(_connectionString) { AccessToken = accessToken.Token })
            {
                await connection.OpenAsync();
                var selectCommand = connection.CreateCommand();
                selectCommand.CommandText = "SELECT TenantId, TenantName FROM Tenants";

                using var reader = await selectCommand.ExecuteReaderAsync();
                while (await reader.ReadAsync())
                {
                    tenantRecords.Add((reader["TenantId"].ToString(), reader["TenantName"].ToString()));
                }
            }

            var updatedTenants = new List<string>();

            using (var connection = new SqlConnection(_connectionString) { AccessToken = accessToken.Token })
            {
                await connection.OpenAsync();

                foreach (var (tenantId, tenantName) in tenantRecords)
                {
                    logger.LogInformation("🔍 Checking tenant {0} - {1}", tenantName, tenantId);

                    bool isCompliant = false;
                    bool isBackup = false;

                    try
                    {
                        var graphCredential = new ClientSecretCredential(tenantId, _clientId, _clientSecret);
                        var graphClient = new GraphServiceClient(graphCredential);

                        var servicePrincipals = await graphClient.ServicePrincipals
                            .GetAsync(config =>
                            {
                                config.QueryParameters.Filter = $"appId eq '{_graphAppId}'";
                                config.QueryParameters.Select = new[] { "id" };
                            });

                        isCompliant = servicePrincipals?.Value?.Count > 0;
                        logger.LogInformation("✅ Tenant {0} compliance: {1}", tenantName, isCompliant);
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning("⚠️ Error checking consent for tenant {0}: {1}", tenantId, ex.Message);
                    }

                    try
                    {
                        var backupGraphCredential = new ClientSecretCredential(tenantId, _backupAppId, _backupAppSecret);
                        var backupGraphClient = new GraphServiceClient(backupGraphCredential);

                        var backupPrincipals = await backupGraphClient.ServicePrincipals
                            .GetAsync(config =>
                            {
                                config.QueryParameters.Filter = $"appId eq '{_backupAppId}'";
                                config.QueryParameters.Select = new[] { "id" };
                            });

                        isBackup = backupPrincipals?.Value?.Count > 0;
                        logger.LogInformation("💾 Tenant {0} backup compliance: {1}", tenantName, isBackup);
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning("⚠️ Error checking backup consent for tenant {0}: {1}", tenantId, ex.Message);
                    }

                    var updateCommand = connection.CreateCommand();
                    updateCommand.CommandText = "UPDATE Tenants SET IsActive = @isActive, IsBackup = @isBackup WHERE TenantId = @tenantId";
                    updateCommand.Parameters.AddWithValue("@isActive", isCompliant);
                    updateCommand.Parameters.AddWithValue("@isBackup", isBackup);
                    updateCommand.Parameters.AddWithValue("@tenantId", tenantId);
                    await updateCommand.ExecuteNonQueryAsync();

                    updatedTenants.Add($"{tenantName} ({tenantId}): {(isCompliant ? "✅" : "❌")} / Backup: {(isBackup ? "✅" : "❌")}");
                }
            }

            await response.WriteAsJsonAsync(new { Updated = updatedTenants });
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
