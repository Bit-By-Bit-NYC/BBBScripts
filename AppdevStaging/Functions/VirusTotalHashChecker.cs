using System.Net;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

public class VirusTotalHashChecker
{
    private readonly ILogger _logger;
    private readonly HttpClient _httpClient = new HttpClient();
    private readonly string _vtApiKey = Environment.GetEnvironmentVariable("VT_API_KEY");

    public VirusTotalHashChecker(ILoggerFactory loggerFactory)
    {
        _logger = loggerFactory.CreateLogger<VirusTotalHashChecker>();
    }

    [Function("CheckHashes")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post")] HttpRequestData req)
    {
        _logger.LogInformation("CheckHashes function triggered.");

        var results = new List<object>();

        using var reader = new StreamReader(req.Body);
        var csv = await reader.ReadToEndAsync();

        if (string.IsNullOrWhiteSpace(csv))
        {
            _logger.LogWarning("Empty request body received.");
            var badRequest = req.CreateResponse(HttpStatusCode.BadRequest);
            await badRequest.WriteStringAsync("No CSV data found.");
            return badRequest;
        }

        var lines = csv.Split('\n').Skip(1);
        int lineIndex = 1;

        foreach (var line in lines)
        {
            lineIndex++;
            var parts = line.Split(',');
            if (parts.Length < 2)
            {
                _logger.LogWarning($"Skipping line {lineIndex}: not enough columns.");
                continue;
            }

            var hash = parts[1].Trim();
            if (string.IsNullOrWhiteSpace(hash) || hash == "Hash")
            {
                _logger.LogWarning($"Skipping line {lineIndex}: hash missing or header row.");
                continue;
            }

            _logger.LogInformation($"Checking hash: \"{hash}\"");

            var vtUrl = $"https://www.virustotal.com/api/v3/files/{hash}";
            var request = new HttpRequestMessage(HttpMethod.Get, vtUrl);
            request.Headers.Add("x-apikey", _vtApiKey);

            try
            {
                var response = await _httpClient.SendAsync(request);
                var content = await response.Content.ReadAsStringAsync();

                if (!response.IsSuccessStatusCode)
                {
                    _logger.LogWarning($"VirusTotal returned error for hash \"{hash}\": {response.StatusCode} - {content}");
                    results.Add(new
                    {
                        Path = parts.Length > 2 ? parts[2].Trim() : "(unknown)",
                        Hash = hash,
                        Status = "NotFound",
                        Malicious = 0,
                        Suspicious = 0,
                        Undetected = 0
                    });
                    continue;
                }

                using var jsonDoc = JsonDocument.Parse(content);
                var stats = jsonDoc.RootElement.GetProperty("data").GetProperty("attributes").GetProperty("last_analysis_stats");

                results.Add(new
                {
                    Path = parts.Length > 2 ? parts[2].Trim() : "(unknown)",
                    Hash = hash,
                    Status = "Found",
                    Malicious = stats.GetProperty("malicious").GetInt32(),
                    Suspicious = stats.GetProperty("suspicious").GetInt32(),
                    Undetected = stats.GetProperty("undetected").GetInt32()
                });
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, $"Exception while processing hash {hash} on line {lineIndex}");
                results.Add(new
                {
                    Path = parts.Length > 2 ? parts[2].Trim() : "(unknown)",
                    Hash = hash,
                    Status = "Error",
                    Malicious = 0,
                    Suspicious = 0,
                    Undetected = 0,
                    Error = ex.Message
                });
            }

            await Task.Delay(16000); // Rate limit
        }

        _logger.LogInformation("Finished processing hashes.");

        var res = req.CreateResponse(HttpStatusCode.OK);
        await res.WriteAsJsonAsync(results);
        return res;
    }
}