using System.Net;
using Azure.Identity;
using Azure.ResourceManager;
using Azure.ResourceManager.RecoveryServices;

public class Vaults
{
    [Function("vaults")]
    public static async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "vaults")] HttpRequestData req)
    {
        var cred = new DefaultAzureCredential();
        var arm = new ArmClient(cred);

        var results = new List<object>();

        // Enumerate all subscriptions this identity can see
        await foreach (var sub in arm.GetSubscriptions().GetAllAsync())
        {
            var subClient = arm.GetSubscriptionResource(sub.Data.Id);

            // List Recovery Services Vaults in this subscription
            await foreach (RecoveryServicesVaultResource v in subClient.GetRecoveryServicesVaults().GetAllAsync())
            {
                results.Add(new {
                    name = v.Data.Name,
                    resourceGroup = v.Data.ResourceGroupName,
                    subscriptionId = sub.Data.SubscriptionId,
                    location = v.Data.Location.ToString()
                });
            }
        }

        var resp = req.CreateResponse(HttpStatusCode.OK);
        await resp.WriteAsJsonAsync(results);
        return resp;
    }
}