using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using Azure.Core;
using Azure.Identity;
using Azure.ResourceManager;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;

public class Vaults
{
    static readonly string ApiVersion = Environment.GetEnvironmentVariable("ASR_API") ?? "2024-04-01";

    // Minimal shapes for ARM list responses
    public record ArmList<T>([property: JsonPropertyName("value")] IEnumerable<T> Value);
    public record GenericResource(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("location")] string? Location
    );

    [Function("vaults")]
    public static async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "vaults")] HttpRequestData req)
    {
        var cred = new DefaultAzureCredential();
        var arm = new ArmClient(cred);

        // Acquire ARM token for REST calls
        var token = await cred.GetTokenAsync(new TokenRequestContext(new[] { "https://management.azure.com/.default" }));
        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token.Token);

        var rows = new List<object>();

        // Enumerate all subscriptions visible to this identity
        await foreach (var sub in arm.GetSubscriptions().GetAllAsync())
        {
            var subId = sub.Data.SubscriptionId;
            var url = $"https://management.azure.com/subscriptions/{subId}/providers/Microsoft.RecoveryServices/vaults?api-version={ApiVersion}";
            var list = await GetSafeAsync<ArmList<GenericResource>>(http, url);

            foreach (var v in list?.Value ?? Enumerable.Empty<GenericResource>())
            {
                rows.Add(new {
                    name = v.Name,
                    resourceGroup = ExtractResourceGroup(v.Id),
                    subscriptionId = subId,
                    location = v.Location ?? ""
                });
            }
        }

        var resp = req.CreateResponse(HttpStatusCode.OK);
        await resp.WriteAsJsonAsync(rows);
        return resp;
    }

    static async Task<T?> GetSafeAsync<T>(HttpClient http, string url)
    {
        var r = await http.GetAsync(url);
        if (!r.IsSuccessStatusCode) return default;
        try { return await r.Content.ReadFromJsonAsync<T>(); } catch { return default; }
    }

    static string ExtractResourceGroup(string id)
    {
        // /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.RecoveryServices/vaults/{name}
        var parts = id.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var i = Array.FindIndex(parts, p => p.Equals("resourceGroups", StringComparison.OrdinalIgnoreCase));
        return (i >= 0 && i + 1 < parts.Length) ? parts[i + 1] : "";
    }
}