using System.Net;
using System.Net.Http.Json;
using Azure.Core;
using Azure.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;

public class AsrSummary
{
    static readonly string ApiVersion = Environment.GetEnvironmentVariable("ASR_API") ?? "2024-04-01";

    record ArmList<T>(IEnumerable<T> value);
    record Fabric(string name, dynamic properties);
    record Container(string name, dynamic properties);
    record Rpi(string name, dynamic properties);

    [Function("asr-summary")]
    public static async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "asr-summary")] HttpRequestData req)
    {
        var q = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        var subId = q["subId"]; var rg = q["rg"]; var vault = q["vault"];
        if (string.IsNullOrWhiteSpace(subId) || string.IsNullOrWhiteSpace(rg) || string.IsNullOrWhiteSpace(vault))
            return await Bad(req, "subId, rg, vault are required");

        var cred = new DefaultAzureCredential();
        var token = await cred.GetTokenAsync(new TokenRequestContext(new[] { "https://management.azure.com/.default" }));
        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token.Token);

        async Task<T?> GetAsync<T>(string url)
        {
            var r = await http.GetAsync(url);
            if (!r.IsSuccessStatusCode) return default;
            try { return await r.Content.ReadFromJsonAsync<T>(); } catch { return default; }
        }

        string baseUrl = $"https://management.azure.com/subscriptions/{subId}/resourceGroups/{rg}"
            + $"/providers/Microsoft.RecoveryServices/vaults/{vault}";

        var fabrics = await GetAsync<ArmList<Fabric>>($"{baseUrl}/replicationFabrics?api-version={ApiVersion}");
        int total = 0;
        var fabricObjs = new List<object>();

        foreach (var f in fabrics?.value ?? Enumerable.Empty<Fabric>())
        {
            var containers = await GetAsync<ArmList<Container>>(
                $"{baseUrl}/replicationFabrics/{f.name}/replicationProtectionContainers?api-version={ApiVersion}");

            var contObjs = new List<object>();
            foreach (var c in containers?.value ?? Enumerable.Empty<Container>())
            {
                var rpis = await GetAsync<ArmList<Rpi>>(
                    $"{baseUrl}/replicationFabrics/{f.name}/replicationProtectionContainers/{c.name}/replicationProtectedItems?api-version={ApiVersion}");
                int count = rpis?.value?.Count() ?? 0;
                total += count;
                contObjs.Add(new { name = c.properties?.friendlyName ?? c.name, id = $"/{f.name}/{c.name}", replicatedItemCount = count });
            }
            fabricObjs.Add(new { name = f.properties?.friendlyName ?? f.name, id = f.name, protectionContainers = contObjs });
        }

        var payload = new {
            subscriptionId = subId, subscriptionName = (string?)null, resourceGroup = rg,
            vaultName = vault, location = (string?)null,
            replicatedItemTotal = total, fabrics = fabricObjs,
            generatedAtUtc = DateTime.UtcNow.ToString("s") + "Z"
        };

        var resp = req.CreateResponse(HttpStatusCode.OK);
        await resp.WriteAsJsonAsync(payload);
        return resp;
    }

    static async Task<HttpResponseData> Bad(HttpRequestData req, string msg)
    {
        var r = req.CreateResponse(HttpStatusCode.BadRequest);
        await r.WriteStringAsync(msg);
        return r;
    }
}