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
using System.Linq;

public class GetTenants
{
    private readonly string _connectionString;

    public GetTenants()
    {
        _connectionString = "Server=tcp:bbbai.database.windows.net,1433;Initial Catalog=bbbazuredb;";
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
            var credential = new DefaultAzureCredential();
            var tokenRequestContext = new TokenRequestContext(new[] { "https://database.windows.net/.default" });
            var accessToken = await credential.GetTokenAsync(tokenRequestContext);

            using var connection = new SqlConnection(_connectionString) { AccessToken = accessToken.Token };
            await connection.OpenAsync();

            var command = connection.CreateCommand();
            command.CommandText = "SELECT TenantName, TenantId, IsActive FROM Tenants";

            var tenants = new List<Dictionary<string, object>>();
            using var reader = await command.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                tenants.Add(new Dictionary<string, object>
                {
                    { "TenantName", reader["TenantName"].ToString() },
                    { "TenantId", reader["TenantId"].ToString() },
                    { "IsActive", (bool)reader["IsActive"] }
                });
            }

            tenants = tenants.OrderBy(t => t["TenantName"].ToString()).ToList();

            logger.LogInformation("📥 Retrieved {0} tenants.", tenants.Count);
            response.StatusCode = HttpStatusCode.OK;
            await response.WriteStringAsync(JsonSerializer.Serialize(tenants));
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