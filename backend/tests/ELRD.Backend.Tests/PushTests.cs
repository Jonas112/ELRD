using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using ElrdBackend.Push;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace ElrdBackend.Tests;

/// <summary>Schritt 144: Push-Mitteilungen (Apple wird durch einen Ersatz-Transport vertreten).</summary>
public static class PushTests
{
    private const string AdminKey = "test-admin-schluessel-1234";
    private static readonly string Token = string.Concat(Enumerable.Repeat("ab", 32));

    private sealed class FakeTransport : PushTransport
    {
        public ConcurrentQueue<(Uri Url, IReadOnlyDictionary<string, string> Headers, JsonObject Body)> Calls { get; } = new();
        public ConcurrentQueue<(int, string)> Replies { get; } = new();

        public override Task<(int Status, string Body)> SendAsync(Uri url, IReadOnlyDictionary<string, string> headers, byte[] body, CancellationToken token)
        {
            Calls.Enqueue((url, new Dictionary<string, string>(headers), JsonNode.Parse(body)!.AsObject()));
            return Task.FromResult(Replies.TryDequeue(out var reply) ? reply : (200, ""));
        }
    }

    public static void TokenIsValidEs256()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var token = PushNotifier.CreateToken("TEAM123456", "KEY1234567", key, DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
        var parts = token.Split('.');
        Assert.Equal(3, parts.Length);
        static byte[] Decode(string text) => Convert.FromBase64String(text.Replace('-', '+').Replace('_', '/') + new string('=', (4 - text.Length % 4) % 4));
        var header = JsonNode.Parse(Decode(parts[0]))!;
        Assert.Equal("ES256", header["alg"]!.GetValue<string>());
        Assert.Equal("KEY1234567", header["kid"]!.GetValue<string>());
        var claims = JsonNode.Parse(Decode(parts[1]))!;
        Assert.Equal("TEAM123456", claims["iss"]!.GetValue<string>());
        Assert.Equal(1_700_000_000L, claims["iat"]!.GetValue<long>());
        Assert.True(key.VerifyData(Encoding.ASCII.GetBytes($"{parts[0]}.{parts[1]}"), Decode(parts[2]), HashAlgorithmName.SHA256));
    }

    public static async Task NewAlarmIsPushedAndDevicesManaged()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var transport = new FakeTransport();
        var temp = new TempStore();
        using var _ = temp;
        var app = BackendApp.Build([], builder =>
        {
            builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Elrd:Storage:DataDirectory"] = temp.Directory,
                ["Elrd:Admin:Key"] = AdminKey,
                ["Elrd:Debug:Enabled"] = "true",
                ["Elrd:Mqtt:Enabled"] = "false",
                ["Elrd:Push:Enabled"] = "true",
                ["Elrd:Push:TeamId"] = "TEAM123456",
                ["Elrd:Push:KeyId"] = "KEY1234567",
                ["Elrd:Push:Key"] = key.ExportPkcs8PrivateKeyPem(),
            });
            builder.Services.AddSingleton<PushTransport>(transport);
            builder.WebHost.UseUrls("http://127.0.0.1:0");
            builder.Logging.ClearProviders();
        });
        await app.StartAsync();
        await using var __ = app;
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        using var client = new HttpClient { BaseAddress = new Uri(address) };

        HttpRequestMessage Admin(HttpMethod method, string path, object? body = null)
        {
            var request = new HttpRequestMessage(method, path);
            request.Headers.Add("X-Admin-Key", AdminKey);
            if (body is not null) request.Content = JsonContent.Create(body);
            return request;
        }

        var created = await (await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/organisations", new { id = "test-rd", name = "Test RD" })))
            .Content.ReadFromJsonAsync<JsonObject>();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", created!["apiKey"]!.GetValue<string>());

        // Noch kein Gerät → Test-Mitteilung abgelehnt.
        Assert.Equal(HttpStatusCode.BadRequest, (await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/organisations/test-rd/push-test"))).StatusCode);

        var registered = await client.PostAsJsonAsync("/api/v1/devices", new { token = Token.ToUpperInvariant(), environment = "sandbox" });
        Assert.Equal(HttpStatusCode.OK, registered.StatusCode);
        Assert.True((await registered.Content.ReadFromJsonAsync<JsonObject>())!["pushEnabled"]!.GetValue<bool>());
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/v1/devices", new { token = "xyz" })).StatusCode);
        Assert.True((await client.GetFromJsonAsync<JsonObject>("/api/v1/ping"))!["pushEnabled"]!.GetValue<bool>());

        // Neuer Einsatz → eine Mitteilung ohne Patientendaten.
        var delivery = await (await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/debug/test-rd/alarms", new { sampleId = "bus" })))
            .Content.ReadFromJsonAsync<JsonObject>();
        var alarmId = delivery!["alarm"]!["id"]!.GetValue<string>();
        await WaitAsync(() => transport.Calls.Count == 1);
        var (url, headers, body) = transport.Calls.Single();
        Assert.Equal($"https://api.sandbox.push.apple.com/3/device/{Token}", url.ToString());
        Assert.Equal("ELRD.App", headers["apns-topic"]);
        Assert.Equal($"alamos-{alarmId}", headers["apns-collapse-id"]);
        Assert.True(headers["authorization"].StartsWith("bearer ey", StringComparison.Ordinal));
        Assert.Equal(alarmId, body["elrd"]!["alarmId"]!.GetValue<string>());
        Assert.True(body["aps"]!["alert"]!["body"]!.GetValue<string>().Contains("RD 4", StringComparison.Ordinal));
        Assert.True(!body.ToJsonString().Contains("patient", StringComparison.OrdinalIgnoreCase), "keine Patientendaten");

        // Änderung → keine weitere Mitteilung.
        await client.SendAsync(Admin(HttpMethod.Post, $"/admin/api/debug/test-rd/alarms/{alarmId}/simulate", new { change = "patient" }));
        await Task.Delay(200);
        Assert.Equal(1, transport.Calls.Count);

        // Test-Mitteilung; Apple lehnt das Gerät ab → wird entfernt.
        transport.Replies.Enqueue((410, "{\"reason\":\"Unregistered\"}"));
        var test = await (await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/organisations/test-rd/push-test")))
            .Content.ReadFromJsonAsync<JsonObject>();
        Assert.Equal(1, test!["failed"]!.GetValue<int>());
        Assert.Equal("Unregistered", test["results"]![0]!["reason"]!.GetValue<string>());
        var organisations = await (await client.SendAsync(Admin(HttpMethod.Get, "/admin/api/organisations"))).Content.ReadFromJsonAsync<JsonArray>();
        Assert.Equal(0, organisations![0]!["devices"]!.GetValue<int>());

        // An- und Abmelden.
        await client.PostAsJsonAsync("/api/v1/devices", new { token = Token, environment = "production" });
        var status = await (await client.SendAsync(Admin(HttpMethod.Get, "/admin/api/status"))).Content.ReadFromJsonAsync<JsonObject>();
        Assert.Equal(1, status!["push"]!["devices"]!.GetValue<int>());
        Assert.True(status["push"]!["configured"]!.GetValue<bool>());
        Assert.Equal(HttpStatusCode.NoContent, (await client.DeleteAsync($"/api/v1/devices/{Token}")).StatusCode);
        status = await (await client.SendAsync(Admin(HttpMethod.Get, "/admin/api/status"))).Content.ReadFromJsonAsync<JsonObject>();
        Assert.Equal(0, status!["push"]!["devices"]!.GetValue<int>());
    }

    public static async Task WithoutSettingsPushIsOff()
    {
        var temp = new TempStore();
        using var _ = temp;
        var app = BackendApp.Build([], builder =>
        {
            builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Elrd:Storage:DataDirectory"] = temp.Directory,
                ["Elrd:Push:Enabled"] = "true",
                ["Elrd:Push:KeyFile"] = Path.Combine(temp.Directory, "fehlt.p8"),
            });
            builder.Logging.ClearProviders();
        });
        await using var __ = app;
        var push = app.Services.GetRequiredService<PushNotifier>();
        Assert.True(!push.Configured);
        Assert.NotNull(push.LastError);
    }

    private static async Task WaitAsync(Func<bool> condition)
    {
        for (var i = 0; i < 50 && !condition(); i++) await Task.Delay(50);
        Assert.True(condition(), "Zeitüberschreitung");
    }
}
