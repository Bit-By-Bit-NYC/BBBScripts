using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Azure.Identity;
using Microsoft.Graph;
using Microsoft.Graph.Models;

namespace AppdevStaging.Functions
{
    public static class BookingsDirectory
    {
        [Function("BookingsDirectory")]
        public static async Task<HttpResponseData> Run(
            [HttpTrigger(AuthorizationLevel.Anonymous, "get")] HttpRequestData req,
            FunctionContext context)
        {
            var log = context.GetLogger("BookingsDirectory");
            log.LogInformation("📥 BookingsDirectory triggered.");

            string tenantId = Environment.GetEnvironmentVariable("TENANT_ID")!;
            string clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")!;
            string clientSecret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET")!;

            try
            {
                // 📦 Test path (bypass Graph)
                if (req.Url.Query.Contains("test=true"))
                {
                    log.LogInformation("🧪 Test mode triggered via ?test=true.");
                    var testResponse = req.CreateResponse(HttpStatusCode.OK);
                    await testResponse.WriteAsJsonAsync(new[]
                    {
                        new { name = "Test Engineer", url = "https://outlook.office365.com/book/testuser@yourdomain.com" }
                    });
                    return testResponse;
                }

                log.LogInformation("🔐 Creating Graph credential...");
                var credential = new ClientSecretCredential(tenantId, clientId, clientSecret);

                log.LogInformation("⚙️ Instantiating GraphServiceClient...");
                var graphClient = new GraphServiceClient(credential);

                log.LogInformation("📡 Calling Microsoft Graph: bookingBusinesses...");
                var response = await graphClient.Solutions.BookingBusinesses.GetAsync(config =>
                {
                    config.QueryParameters.Select = new[] { "displayName", "webSiteUrl" };
                    config.QueryParameters.Top = 100;
                });

                if (response?.Value == null || response.Value.Count == 0)
                {
                    log.LogWarning("⚠ No bookingBusinesses returned from Graph.");
                }

                foreach (var b in response?.Value ?? new List<BookingBusiness>())
                {
                    log.LogInformation($"📇 {b.DisplayName} → {b.WebSiteUrl}");
                }

                var businesses = response?.Value ?? new List<BookingBusiness>();

                var results = businesses
                    .Where(b => !string.IsNullOrWhiteSpace(b.WebSiteUrl))
                    .Select(b => new
                    {
                        name = b.DisplayName ?? "Unnamed Booking Page",
                        url = b.WebSiteUrl!
                    })
                    .ToList();

                var httpResponse = req.CreateResponse(HttpStatusCode.OK);
                await httpResponse.WriteAsJsonAsync(results);
                return httpResponse;
            }
            catch (Exception ex)
            {
                log.LogError($"❌ Exception: {ex.GetType().Name} - {ex.Message}");
                log.LogError($"🔍 Stack Trace:\n{ex.StackTrace}");

                if (ex.InnerException != null)
                {
                    log.LogError($"🔍 Inner Exception: {ex.InnerException.GetType().Name} - {ex.InnerException.Message}");
                    log.LogError($"🧵 Inner Stack Trace:\n{ex.InnerException.StackTrace}");
                }

                var errorResponse = req.CreateResponse(HttpStatusCode.InternalServerError);
                await errorResponse.WriteAsJsonAsync(new
                {
                    error = ex.Message,
                    inner = ex.InnerException?.Message,
                    type = ex.GetType().Name,
                    stack = ex.StackTrace
                });
                return errorResponse;
            }
        }
    }
}