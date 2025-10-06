using System.Net;
using Azure.Identity;
using Azure.ResourceManager;
using Azure.ResourceManager.ResourceGraph;
using Azure.ResourceManager.ResourceGraph.Models;

public class Vaults
{
    [Function("vaults")]
    public static async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "vaults")] HttpRequestData req)
    {
        var cred = new DefaultAzureCredential();
        var arm = new ArmClient(cred);

        // Query all subscriptions visible to MI
        var subIds = await arm.GetDefaultSubscriptionAsync();
        var subs = new List<string>();
        await foreach (var s in arm.GetSubscriptions().GetAllAsync()) subs.Add(s.Data.SubscriptionId);

        // Resource Graph query to list RSVs
        var query = new QueryRequest(subs, @"resources
            | where type == 'microsoft.recoveryservices/vaults'
            | project name, resourceGroup, subscriptionId, location");

        var client = new ResourceGraphClient(cred);
        var res = await client.ResourcesAsync(query);

        var rows = ((IEnumerable<IDictionary<string, object>>)res.Data!).Select(r => new {
            name = r["name"], resourceGroup = r["resourceGroup"],
            subscriptionId = r["subscriptionId"], location = r["location"]
        });

        var resp = req.CreateResponse(HttpStatusCode.OK);
        await resp.WriteAsJsonAsync(rows);
        return resp;
    }
}