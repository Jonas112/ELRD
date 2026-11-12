using ElrdBackend.Alamos;
using ElrdBackend.Options;
using ElrdBackend.Security;
using Microsoft.Extensions.Options;

namespace ElrdBackend.Mqtt;

public sealed record MqttStatus(
    bool Enabled,
    bool Connected,
    string Broker,
    string Subscription,
    string? LastError,
    DateTimeOffset? ConnectedSince,
    DateTimeOffset? LastMessageAt,
    long MessagesReceived);

/// <summary>
/// Hält die Verbindung zum MQTT-Broker: abonniert <c>{Präfix}/+/alarm</c>, legt
/// eingehende Einsätze in der Schublade ab, verbindet nach Abbrüchen neu
/// (2 s, 4 s … höchstens 60 s). Senden nutzt die Debug-Seite (ganze Kette testen).
/// </summary>
public sealed class MqttBridge(
    IOptions<BackendOptions> options,
    AlarmIngest ingest,
    Organisations organisations,
    TimeProvider time,
    ILogger<MqttBridge> logger) : BackgroundService
{
    private readonly MqttOptions _options = options.Value.Mqtt;
    private readonly Lock _gate = new();
    private MqttConnection? _connection;
    private string? _lastError;
    private DateTimeOffset? _connectedSince;
    private DateTimeOffset? _lastMessageAt;
    private long _received;

    public string Prefix => _options.TopicPrefix.Trim().Trim('/');
    public string Subscription => $"{Prefix}/+/alarm";
    public string AlarmTopic(string organisationId) => $"{Prefix}/{organisationId}/alarm";

    public MqttStatus Status
    {
        get
        {
            lock (_gate)
            {
                return new MqttStatus(
                    _options.Enabled,
                    _connection is not null,
                    $"{(_options.UseTls ? "mqtts" : "mqtt")}://{_options.Host}:{_options.Port}",
                    Subscription,
                    _lastError,
                    _connectedSince,
                    _lastMessageAt,
                    Interlocked.Read(ref _received));
            }
        }
    }

    /// <summary>Organisation aus <c>{Präfix}/{organisation}/alarm</c> oder <c>null</c>.</summary>
    public string? OrganisationFromTopic(string topic)
    {
        var start = Prefix + "/";
        const string end = "/alarm";
        if (!topic.StartsWith(start, StringComparison.Ordinal) || !topic.EndsWith(end, StringComparison.Ordinal)) return null;
        var middle = topic[start.Length..^end.Length];
        return middle.Length > 0 && !middle.Contains('/') ? middle : null;
    }

    /// <summary>Sendet an das Alarm-Topic der Organisation (wie FE2 es täte).</summary>
    public async Task PublishAlarmAsync(string organisationId, byte[] payload, CancellationToken cancellationToken)
    {
        MqttConnection? connection;
        lock (_gate) connection = _connection;
        if (connection is null) throw new InvalidOperationException("MQTT ist nicht verbunden.");
        await connection.PublishAsync(AlarmTopic(organisationId), payload, retain: false, cancellationToken);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled)
        {
            logger.LogInformation("MQTT ist ausgeschaltet (Elrd:Mqtt:Enabled).");
            return;
        }
        var delay = TimeSpan.FromSeconds(2);
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using var connection = await MqttConnection.ConnectAsync(Settings(), stoppingToken);
                await connection.SubscribeAsync(Subscription, qos: 1, stoppingToken);
                lock (_gate)
                {
                    _connection = connection;
                    _connectedSince = time.GetUtcNow();
                    _lastError = null;
                }
                logger.LogInformation("MQTT verbunden mit {Host}:{Port}, abonniert {Topic}", _options.Host, _options.Port, Subscription);
                delay = TimeSpan.FromSeconds(2);

                await foreach (var message in connection.Messages.ReadAllAsync(stoppingToken))
                {
                    Handle(message);
                }
                await connection.Completion;
                throw new MqttException("Verbindung vom Broker getrennt.");
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception error)
            {
                lock (_gate)
                {
                    _connection = null;
                    _connectedSince = null;
                    _lastError = error.Message;
                }
                logger.LogWarning("MQTT: {Error} – neuer Versuch in {Seconds} s", error.Message, delay.TotalSeconds);
                try { await Task.Delay(delay, stoppingToken); } catch (OperationCanceledException) { break; }
                delay = TimeSpan.FromSeconds(Math.Min(60, delay.TotalSeconds * 2));
            }
        }
        lock (_gate) _connection = null;
    }

    private void Handle(MqttMessage message)
    {
        Interlocked.Increment(ref _received);
        lock (_gate) _lastMessageAt = time.GetUtcNow();
        if (message.Retain)
        {
            // Gespeicherte Altnachricht vom Broker: nur annehmen, wenn sie neu ist –
            // das entscheidet die Schublade über externalId/Inhalt ohnehin.
            logger.LogDebug("Retained-Nachricht auf {Topic}", message.Topic);
        }
        var organisationId = OrganisationFromTopic(message.Topic);
        if (organisationId is null)
        {
            logger.LogWarning("Unbekanntes Topic {Topic}", message.Topic);
            return;
        }
        if (!organisations.Exists(organisationId))
        {
            logger.LogWarning("Nachricht für unbekannte Organisation {Organisation} verworfen", organisationId);
            return;
        }
        ingest.Ingest(organisationId, message.Payload, source: "mqtt");
    }

    private MqttConnectSettings Settings() => new(
        _options.Host,
        _options.Port,
        _options.UseTls,
        _options.AllowUntrustedCertificates,
        string.IsNullOrWhiteSpace(_options.ClientId) ? "elrd-backend" : _options.ClientId,
        string.IsNullOrWhiteSpace(_options.Username) ? null : _options.Username,
        _options.Password,
        _options.KeepAliveSeconds);
}
