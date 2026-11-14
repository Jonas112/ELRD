using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ElrdBackend.Alamos;
using ElrdBackend.Options;
using ElrdBackend.Storage;
using Microsoft.Extensions.Options;

namespace ElrdBackend.Push;

public sealed record PushStatus(bool Enabled, bool Configured, string BundleId, int Devices, int Sent, DateTimeOffset? LastSentAt, string? LastError);
public sealed record PushDeviceResult(string Device, string Environment, int Status, string Reason);
public sealed record PushSendResult(int Sent, int Failed, IReadOnlyList<PushDeviceResult> Results, string? Error);

/// <summary>Versand einer Mitteilung an Apple (HTTP/2). In Tests ersetzbar.</summary>
public class PushTransport
{
    private readonly HttpClient client = new(new SocketsHttpHandler { PooledConnectionIdleTimeout = TimeSpan.FromMinutes(5) })
    {
        Timeout = TimeSpan.FromSeconds(15),
    };

    public virtual async Task<(int Status, string Body)> SendAsync(Uri url, IReadOnlyDictionary<string, string> headers, byte[] body, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Version = HttpVersion.Version20,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
            Content = new ByteArrayContent(body),
        };
        foreach (var (name, value) in headers) request.Headers.TryAddWithoutValidation(name, value);
        try
        {
            using var response = await client.SendAsync(request, token);
            return ((int)response.StatusCode, await response.Content.ReadAsStringAsync(token));
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            return (0, error.Message);
        }
    }
}

/// <summary>
/// Schritt 144: Push-Mitteilungen über Apple Push Notification service bei neuen Einsätzen.
/// Geräte meldet die App an (<c>POST /api/v1/devices</c>). Inhalt: Stichwort, Beschreibung,
/// Ort – keine Patientendaten. Ungültige Geräte (von Apple abgelehnt) werden entfernt.
/// </summary>
public sealed partial class PushNotifier
{
    public const int MaxDevicesPerOrganisation = 200;
    private static readonly Dictionary<string, string> Hosts = new()
    {
        ["production"] = "https://api.push.apple.com",
        ["sandbox"] = "https://api.sandbox.push.apple.com",
    };
    private static readonly TimeSpan TokenLifetime = TimeSpan.FromMinutes(50);

    private readonly DataStore store;
    private readonly PushOptions options;
    private readonly PushTransport transport;
    private readonly TimeProvider time;
    private readonly ILogger<PushNotifier> logger;
    private readonly ECDsa? key;
    private readonly Lock tokenLock = new();
    private (string Value, DateTimeOffset Created)? bearer;
    private int sent;
    private DateTimeOffset? lastSentAt;

    public PushNotifier(DataStore store, IOptions<BackendOptions> options, PushTransport transport, TimeProvider time, ILogger<PushNotifier> logger)
    {
        this.store = store;
        this.options = options.Value.Push;
        this.transport = transport;
        this.time = time;
        this.logger = logger;
        if (!this.options.Enabled) return;
        string? pem = this.options.Key;
        if (string.IsNullOrWhiteSpace(pem) && !string.IsNullOrWhiteSpace(this.options.KeyFile))
        {
            try { pem = File.ReadAllText(this.options.KeyFile); }
            catch (IOException) { LastError = $"Schlüsseldatei {Path.GetFileName(this.options.KeyFile)} nicht gefunden."; }
            catch (UnauthorizedAccessException) { LastError = "Schlüsseldatei nicht lesbar."; }
        }
        if (string.IsNullOrWhiteSpace(this.options.TeamId) || string.IsNullOrWhiteSpace(this.options.KeyId) || string.IsNullOrWhiteSpace(pem))
        {
            LastError ??= "TeamId, KeyId und KeyFile (oder Key) eintragen.";
        }
        else
        {
            try
            {
                var ecdsa = ECDsa.Create();
                ecdsa.ImportFromPem(pem);
                key = ecdsa;
            }
            catch (Exception error) when (error is ArgumentException or CryptographicException)
            {
                LastError = "Schlüsseldatei unlesbar – erwartet wird die .p8-Datei von Apple.";
            }
        }
        if (LastError is not null) logger.LogWarning("Push-Mitteilungen aus: {Reason}", LastError);
    }

    public bool Configured => options.Enabled && key is not null;
    public string? LastError { get; private set; }

    public PushStatus Status => new(options.Enabled, Configured, options.BundleId, store.Read(s => s.Devices.Count), sent, lastSentAt, LastError);

    // MARK: Geräte

    [GeneratedRegex("^[0-9a-f]{64,200}$")]
    private static partial Regex TokenPattern();

    public void Register(string organisationId, string token, string? environment)
    {
        token = (token ?? "").Trim().ToLowerInvariant();
        if (!TokenPattern().IsMatch(token)) throw new ArgumentException("Gerätekennzeichen ungültig (hexadezimal erwartet).");
        var env = environment is "sandbox" ? "sandbox" : "production";
        var now = time.GetUtcNow();
        store.Write(state =>
        {
            var existing = state.Devices.FirstOrDefault(d => d.Token == token);
            if (existing is not null)
            {
                existing.OrganisationId = organisationId;
                existing.Environment = env;
                existing.LastSeenAt = now;
                return 0;
            }
            var own = state.Devices.Where(d => d.OrganisationId == organisationId).ToList();
            if (own.Count >= MaxDevicesPerOrganisation) state.Devices.Remove(own.MinBy(d => d.LastSeenAt)!);
            state.Devices.Add(new PushDevice { OrganisationId = organisationId, Token = token, Environment = env, RegisteredAt = now, LastSeenAt = now });
            return 1;
        });
        logger.LogInformation("{Organisation}: Gerät {Device} für Mitteilungen angemeldet ({Environment})", organisationId, Short(token), env);
    }

    public bool Unregister(string organisationId, string token)
    {
        token = (token ?? "").Trim().ToLowerInvariant();
        return store.Write(state => state.Devices.RemoveAll(d => d.Token == token && d.OrganisationId == organisationId)) > 0;
    }

    public int DeviceCount(string organisationId) => store.Read(state => state.Devices.Count(d => d.OrganisationId == organisationId));

    public void RemoveOrganisation(string organisationId) => store.Write(state => state.Devices.RemoveAll(d => d.OrganisationId == organisationId));

    // MARK: Senden

    public static JsonObject Payload(StoredAlarm alarm)
    {
        var data = alarm.Data;
        static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text) ? text : null;
        var keyword = Text(data["keyword"]);
        var description = Text(data["keyword_description"]);
        var location = data["location"] as JsonObject;
        var place = Text(location?["city"]) ?? Text(location?["street"]);
        var parts = new[] { keyword, description == keyword ? null : description, place }.Where(p => p is not null);
        var body = string.Join(" · ", parts);
        return new JsonObject
        {
            ["aps"] = new JsonObject
            {
                ["alert"] = new JsonObject
                {
                    ["title"] = alarm.IsTest ? "Neuer Testeinsatz (Alamos FE2)" : "Neuer Einsatz aus Alamos FE2",
                    ["body"] = body.Length > 0 ? body : "Einsatz ohne Stichwort",
                },
                ["sound"] = "default",
                ["thread-id"] = "alamos",
            },
            ["elrd"] = new JsonObject { ["kind"] = "alamos", ["alarmId"] = alarm.Id.ToString(), ["externalId"] = alarm.ExternalId },
        };
    }

    public static JsonObject TestPayload() => new()
    {
        ["aps"] = new JsonObject
        {
            ["alert"] = new JsonObject { ["title"] = "Test-Mitteilung (ELRD-Backend)", ["body"] = "Push-Mitteilungen kommen an." },
            ["sound"] = "default",
            ["thread-id"] = "alamos",
        },
        ["elrd"] = new JsonObject { ["kind"] = "test" },
    };

    public async Task<PushSendResult> SendAsync(string organisationId, JsonObject payload, string? collapseId, CancellationToken token)
    {
        if (!Configured) return new PushSendResult(0, 0, [], LastError ?? "Push-Mitteilungen sind ausgeschaltet.");
        var body = Encoding.UTF8.GetBytes(payload.ToJsonString());
        var headers = new Dictionary<string, string>
        {
            ["authorization"] = $"bearer {Bearer()}",
            ["apns-topic"] = options.BundleId,
            ["apns-push-type"] = "alert",
            ["apns-priority"] = "10",
            ["apns-expiration"] = (time.GetUtcNow().ToUnixTimeSeconds() + 3600).ToString(),
        };
        if (collapseId is not null) headers["apns-collapse-id"] = collapseId.Length > 64 ? collapseId[..64] : collapseId;
        var devices = store.Read(state => state.Devices.Where(d => d.OrganisationId == organisationId).Select(d => (d.Token, d.Environment)).ToList());
        var results = new List<PushDeviceResult>();
        var invalid = new List<string>();
        int ok = 0, failed = 0;
        foreach (var (deviceToken, environment) in devices)
        {
            var host = options.HostOverride?.TrimEnd('/') ?? Hosts.GetValueOrDefault(environment, Hosts["production"]);
            var (status, text) = await transport.SendAsync(new Uri($"{host}/3/device/{deviceToken}"), headers, body, token);
            var reason = "";
            try { reason = string.IsNullOrWhiteSpace(text) ? "" : JsonNode.Parse(text)?["reason"]?.GetValue<string>() ?? ""; }
            catch (Exception error) when (error is JsonException or InvalidOperationException) { reason = text.Length > 120 ? text[..120] : text; }
            if (status == 200)
            {
                ok++;
            }
            else
            {
                failed++;
                if (status == 410 || reason is "BadDeviceToken" or "Unregistered" or "DeviceTokenNotForTopic") invalid.Add(deviceToken);
                LastError = $"Apple: {status} {reason}".Trim();
            }
            results.Add(new PushDeviceResult(Short(deviceToken), environment, status, reason));
        }
        foreach (var deviceToken in invalid)
        {
            Unregister(organisationId, deviceToken);
            logger.LogInformation("{Organisation}: Gerät {Device} entfernt (von Apple abgelehnt)", organisationId, Short(deviceToken));
        }
        if (ok > 0)
        {
            Interlocked.Add(ref sent, ok);
            lastSentAt = time.GetUtcNow();
            if (failed == 0) LastError = null;
        }
        if (ok + failed > 0) logger.LogInformation("{Organisation}: Mitteilung an {Sent} Geräte gesendet, {Failed} fehlgeschlagen", organisationId, ok, failed);
        return new PushSendResult(ok, failed, results, failed == 0 ? null : LastError);
    }

    /// <summary>Vom Eingang: neuer Einsatz → Mitteilung (im Hintergrund).</summary>
    public void OnIngest(string organisationId, IngestResult result)
    {
        if (result.Outcome != IngestOutcome.Created || result.Alarm is not { } alarm || !Configured) return;
        if (alarm.IsTest && !options.IncludeTests) return;
        var payload = Payload(alarm);
        _ = Task.Run(async () =>
        {
            try { await SendAsync(organisationId, payload, $"alamos-{alarm.Id}", CancellationToken.None); }
            catch (Exception error) { logger.LogError(error, "Push-Mitteilung fehlgeschlagen"); }
        });
    }

    /// <summary>Anmelde-Token für Apple (JWT, ES256), höchstens 50 Minuten alt.</summary>
    private string Bearer()
    {
        lock (tokenLock)
        {
            var now = time.GetUtcNow();
            if (bearer is { } current && now - current.Created < TokenLifetime) return current.Value;
            var value = CreateToken(options.TeamId!, options.KeyId!, key!, now);
            bearer = (value, now);
            return value;
        }
    }

    public static string CreateToken(string teamId, string keyId, ECDsa key, DateTimeOffset issuedAt)
    {
        var header = Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { alg = "ES256", kid = keyId }));
        var claims = Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { iss = teamId, iat = issuedAt.ToUnixTimeSeconds() }));
        var signature = key.SignData(Encoding.ASCII.GetBytes($"{header}.{claims}"), HashAlgorithmName.SHA256);
        return $"{header}.{claims}.{Base64Url(signature)}";
    }

    private static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static string Short(string token) => token[..Math.Min(8, token.Length)] + "…";
}
