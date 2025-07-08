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
            logger.LogInformation("🔐 Acquiring token...");
            var credential = new DefaultAzureCredential();
            var tokenRequestContext = new TokenRequestContext(new[] { "https://database.windows.net/.default" });
            var accessToken = await credential.GetTokenAsync(tokenRequestContext);
            logger.LogInformation("✅ Token acquired. Token length: {0}", accessToken.Token.Length);

            // 🔍 Debug token claims
            var handler = new JwtSecurityTokenHandler();
            var token = handler.ReadJwtToken(accessToken.Token);
            var oid = token.Payload.TryGetValue("oid", out var oidVal) ? oidVal?.ToString() : "N/A";
            var upn = token.Payload.TryGetValue("upn", out var upnVal) ? upnVal?.ToString() : "N/A";
            var sub = token.Subject ?? "N/A";

            logger.LogInformation("🔍 Token identity - OID: {0}, UPN: {1}, Subject: {2}", oid, upn, sub);

            logger.LogInformation("🔌 Opening SQL connection...");
            using var connection = new SqlConnection(_connectionString)
            {
                AccessToken = accessToken.Token
            };
            await connection.OpenAsync();

            var command = connection.CreateCommand();
            command.CommandText = "SELECT TenantName, TenantId FROM Tenants";

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
