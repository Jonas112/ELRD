using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.Configuration;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace ElrdBackend.Tests;

/// <summary>Ganze App auf einem freien Port: Verwaltung, Debug, App-Schnittstelle.</summary>
public static class ApiTests
{
    private const string AdminKey = "test-admin-schluessel-1234";

    private static async Task<(WebApplication App, HttpClient Client, TempStore Temp)> StartAsync(
        Dictionary<string, string?>? extra = null)
    {
        var temp = new TempStore();
        var settings = new Dictionary<string, string?>
        {
            ["Elrd:Storage:DataDirectory"] = temp.Directory,
            ["Elrd:Admin:Key"] = AdminKey,
            ["Elrd:Debug:Enabled"] = "true",
            ["Elrd:Mqtt:Enabled"] = "false",
        };
        foreach (var (key, value) in extra ?? []) settings[key] = value;
        var app = BackendApp.Build([], builder =>
        {
            builder.Configuration.AddInMemoryCollection(settings);
            builder.WebHost.UseUrls("http://127.0.0.1:0");
            builder.Logging.ClearProviders();
        });
        await app.StartAsync();
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        var client = new HttpClient { BaseAddress = new Uri(address) };
        return (app, client, temp);
    }

    private static HttpRequestMessage Admin(HttpMethod method, string path, object? body = null)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Add("X-Admin-Key", AdminKey);
        if (body is not null) request.Content = JsonContent.Create(body);
        return request;
    }

    public static async Task AblaufVonTesteinsatzBisApp()
    {
        var (app, client, temp) = await StartAsync();
        await using var _ = app;
        using var __ = temp;

        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health")).StatusCode);

        // Organisation anlegen → Schlüssel einmalig.
        var created = await (await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/organisations", new { id = "test-rd", name = "Test RD" })))
            .Content.ReadFromJsonAsync<JsonObject>();
        var key = created!["apiKey"]!.GetValue<string>();
        Assert.Equal("elrd/test-rd/alarm", created["organisation"]!["topic"]!.GetValue<string>());

        // Ohne / mit falschem Schlüssel: 401.
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/v1/alarms")).StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "falsch");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/v1/alarms")).StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", key);

        var ping = await client.GetFromJsonAsync<JsonObject>("/api/v1/ping");
        Assert.Equal("Test RD", ping!["organisationName"]!.GetValue<string>());

        // Testeinsatz anlegen (direkt).
        var delivery = await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/debug/test-rd/alarms", new { sampleId = "bus", via = "direct" }));
        Assert.Equal(HttpStatusCode.OK, delivery.StatusCode);
        var list = await client.GetFromJsonAsync<JsonObject>("/api/v1/alarms");
        var alarm = list!["alarms"]!.AsArray().Single()!;
        Assert.Equal("RD 4", alarm["data"]!["keyword"]!.GetValue<string>());
        Assert.True(alarm["isTest"]!.GetValue<bool>());
        var serverTime = list["serverTime"]!.GetValue<string>();
        Assert.True(serverTime.EndsWith('Z') && serverTime.Contains('.'), "Zeitformat " + serverTime);

        // since: nichts Neues.
        var since = await client.GetFromJsonAsync<JsonObject>("/api/v1/alarms?since=" + Uri.EscapeDataString(serverTime));
        Assert.Equal(0, since!["alarms"]!.AsArray().Count);

        // Änderung simulieren → kommt mit since.
        await Task.Delay(5);
        var id = alarm["id"]!.GetValue<string>();
        var simulate = await client.SendAsync(Admin(HttpMethod.Post, $"/admin/api/debug/test-rd/alarms/{id}/simulate", new { change = "patient", via = "direct" }));
        Assert.Equal(HttpStatusCode.OK, simulate.StatusCode);
        var changed = await client.GetFromJsonAsync<JsonObject>("/api/v1/alarms?since=" + Uri.EscapeDataString(serverTime));
        var updated = changed!["alarms"]!.AsArray().Single()!;
        Assert.Equal(2, updated["revision"]!.GetValue<int>());
        Assert.Equal(4, updated["data"]!["patient"]!.AsArray().Count);

        // Einzeln abrufen.
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync($"/api/v1/alarms/{id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/api/v1/alarms/{Guid.NewGuid()}")).StatusCode);

        // Geschlossene ausblenden.
        await client.SendAsync(Admin(HttpMethod.Post, $"/admin/api/debug/test-rd/alarms/{id}/simulate", new { change = "close" }));
        var open = await client.GetFromJsonAsync<JsonObject>("/api/v1/alarms?includeClosed=false");
        Assert.Equal(0, open!["alarms"]!.AsArray().Count);
    }

    public static async Task FremdeOrganisationSiehtNichts()
    {
        var (app, client, temp) = await StartAsync();
        await using var _ = app;
        using var __ = temp;
        var a = await (await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/organisations", new { id = "org-a", name = "A" }))).Content.ReadFromJsonAsync<JsonObject>();
        await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/organisations", new { id = "org-b", name = "B" }));
        await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/debug/org-b/alarms", new { sampleId = "vu" }));
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", a!["apiKey"]!.GetValue<string>());
        var list = await client.GetFromJsonAsync<JsonObject>("/api/v1/alarms");
        Assert.Equal(0, list!["alarms"]!.AsArray().Count);
    }

    public static async Task VerwaltungNurMitAdminSchluessel()
    {
        var (app, client, temp) = await StartAsync();
        await using var _ = app;
        using var __ = temp;
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/admin/api/status")).StatusCode);
        var wrong = new HttpRequestMessage(HttpMethod.Get, "/admin/api/status");
        wrong.Headers.Add("X-Admin-Key", "falsch-falsch-falsch-falsch");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(wrong)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Admin(HttpMethod.Get, "/admin/api/status"))).StatusCode);
    }

    public static async Task DebugAusgeschaltet()
    {
        var (app, client, temp) = await StartAsync(new() { ["Elrd:Debug:Enabled"] = "false" });
        await using var _ = app;
        using var __ = temp;
        Assert.Equal(HttpStatusCode.NotFound, (await client.SendAsync(Admin(HttpMethod.Get, "/admin/api/debug/info"))).StatusCode);
    }

    public static async Task OhneAdminSchluesselGesperrt()
    {
        var (app, client, temp) = await StartAsync(new() { ["Elrd:Admin:Key"] = "" });
        await using var _ = app;
        using var __ = temp;
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.SendAsync(Admin(HttpMethod.Get, "/admin/api/status"))).StatusCode);
    }

    public static async Task MqttKetteMitEchtemBroker()
    {
        // Nur wenn ein Broker bereitsteht: ELRD_TEST_MQTT=host:port:benutzer:passwort
        var setting = Environment.GetEnvironmentVariable("ELRD_TEST_MQTT");
        if (string.IsNullOrWhiteSpace(setting)) throw new SkipException("ELRD_TEST_MQTT nicht gesetzt");
        var parts = setting.Split(':');
        var (app, client, temp) = await StartAsync(new()
        {
            ["Elrd:Mqtt:Enabled"] = "true",
            ["Elrd:Mqtt:Host"] = parts[0],
            ["Elrd:Mqtt:Port"] = parts[1],
            ["Elrd:Mqtt:UseTls"] = "false",
            ["Elrd:Mqtt:Username"] = parts[2],
            ["Elrd:Mqtt:Password"] = parts[3],
            ["Elrd:Mqtt:ClientId"] = "elrd-test-" + Guid.NewGuid().ToString("N")[..6],
        });
        await using var _ = app;
        using var __ = temp;
        var created = await (await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/organisations", new { id = "mqtt-test", name = "MQTT" }))).Content.ReadFromJsonAsync<JsonObject>();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", created!["apiKey"]!.GetValue<string>());

        // Warten, bis verbunden.
        for (var i = 0; i < 50; i++)
        {
            var health = await client.GetFromJsonAsync<JsonObject>("/health");
            if (health!["mqtt"]!.GetValue<string>() == "connected") break;
            await Task.Delay(100);
        }
        var sent = await client.SendAsync(Admin(HttpMethod.Post, "/admin/api/debug/mqtt-test/alarms", new { sampleId = "intern", via = "mqtt" }));
        Assert.Equal(HttpStatusCode.OK, sent.StatusCode);
        JsonArray alarms = [];
        for (var i = 0; i < 50 && alarms.Count == 0; i++)
        {
            await Task.Delay(100);
            alarms = (await client.GetFromJsonAsync<JsonObject>("/api/v1/alarms"))!["alarms"]!.AsArray();
        }
        Assert.Equal(1, alarms.Count);
        Assert.Equal("mqtt", alarms[0]!["source"]!.GetValue<string>());
        Assert.True(alarms[0]!["isTest"]!.GetValue<bool>());
    }
}
