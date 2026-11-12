using System.Buffers.Binary;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;

namespace ElrdBackend.Mqtt;

/// <summary>Empfangene Nachricht.</summary>
public sealed record MqttMessage(string Topic, byte[] Payload, int Qos, bool Retain);

public sealed class MqttException(string message) : Exception(message);

public sealed record MqttConnectSettings(
    string Host,
    int Port,
    bool UseTls,
    bool AllowUntrustedCertificates,
    string ClientId,
    string? Username,
    string? Password,
    int KeepAliveSeconds);

/// <summary>
/// Schlanker MQTT-3.1.1-Client (E123): Verbinden (optional TLS, Benutzer/Passwort),
/// Abonnieren, Empfangen mit QoS 0/1/2, Senden mit QoS 0, Keep-Alive.
/// Mehr braucht die Schublade nicht; Wiederverbinden übernimmt <see cref="MqttBridge"/>.
/// </summary>
public sealed class MqttConnection : IAsyncDisposable
{
    private const byte Connect = 0x10, ConnAck = 0x20, Publish = 0x30, PubAck = 0x40, PubRec = 0x50,
        PubRel = 0x60, PubComp = 0x70, Subscribe = 0x80, SubAck = 0x90, PingReq = 0xC0, PingResp = 0xD0, Disconnect = 0xE0;

    private readonly TcpClient _tcp;
    private readonly Stream _stream;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Channel<MqttMessage> _messages = Channel.CreateUnbounded<MqttMessage>();
    private readonly Dictionary<ushort, TaskCompletionSource<byte[]>> _pendingSubscriptions = [];
    private readonly HashSet<ushort> _qos2InFlight = [];
    private readonly int _keepAliveSeconds;
    private readonly byte[] _oneByte = new byte[1];
    private ushort _nextPacketId;
    private long _lastReceivedTicks = Environment.TickCount64;
    private Task _readLoop = Task.CompletedTask;
    private Task _pingLoop = Task.CompletedTask;

    private MqttConnection(TcpClient tcp, Stream stream, int keepAliveSeconds)
    {
        _tcp = tcp;
        _stream = stream;
        _keepAliveSeconds = Math.Max(5, keepAliveSeconds);
    }

    /// <summary>Empfangene Nachrichten; endet, wenn die Verbindung abbricht.</summary>
    public ChannelReader<MqttMessage> Messages => _messages.Reader;

    /// <summary>Endet, wenn die Verbindung getrennt wurde (Fehler als Ausnahme).</summary>
    public Task Completion => _readLoop;

    public static async Task<MqttConnection> ConnectAsync(MqttConnectSettings settings, CancellationToken cancellationToken)
    {
        var tcp = new TcpClient { NoDelay = true };
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            await tcp.ConnectAsync(settings.Host, settings.Port, timeout.Token);
            Stream stream = tcp.GetStream();
            if (settings.UseTls)
            {
                var ssl = new SslStream(stream, leaveInnerStreamOpen: false);
                await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
                {
                    TargetHost = settings.Host,
                    RemoteCertificateValidationCallback = settings.AllowUntrustedCertificates ? (_, _, _, _) => true : null,
                }, timeout.Token);
                stream = ssl;
            }
            var connection = new MqttConnection(tcp, stream, settings.KeepAliveSeconds);
            await connection.HandshakeAsync(settings, timeout.Token);
            connection._readLoop = connection.ReadLoopAsync();
            connection._pingLoop = connection.PingLoopAsync();
            return connection;
        }
        catch
        {
            tcp.Dispose();
            throw;
        }
    }

    public async Task SubscribeAsync(string topicFilter, int qos, CancellationToken cancellationToken)
    {
        var id = NextPacketId();
        var completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_pendingSubscriptions) _pendingSubscriptions[id] = completion;
        var body = new List<byte>();
        AppendUInt16(body, id);
        AppendString(body, topicFilter);
        body.Add((byte)Math.Clamp(qos, 0, 2));
        await WriteAsync((byte)(Subscribe | 0x02), body, cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        var granted = await completion.Task.WaitAsync(timeout.Token);
        if (granted.Length == 0 || granted[0] == 0x80) throw new MqttException($"Broker verweigert das Abonnement „{topicFilter}“ (Rechte/ACL prüfen).");
    }

    /// <summary>Sendet mit QoS 0.</summary>
    public Task PublishAsync(string topic, ReadOnlyMemory<byte> payload, bool retain, CancellationToken cancellationToken)
    {
        var body = new List<byte>(payload.Length + topic.Length + 2);
        AppendString(body, topic);
        body.AddRange(payload.ToArray());
        return WriteAsync((byte)(Publish | (retain ? 1 : 0)), body, cancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        if (!_lifetime.IsCancellationRequested)
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await WriteAsync(Disconnect, [], timeout.Token);
            }
            catch
            {
                // Verbindung ist ohnehin weg.
            }
            await _lifetime.CancelAsync();
        }
        _stream.Dispose();
        _tcp.Dispose();
        try { await Task.WhenAll(_readLoop, _pingLoop); } catch { /* beendet */ }
        _lifetime.Dispose();
        _writeGate.Dispose();
    }

    // MARK: Ablauf

    private async Task HandshakeAsync(MqttConnectSettings settings, CancellationToken cancellationToken)
    {
        var body = new List<byte>();
        AppendString(body, "MQTT");
        body.Add(4); // Protokollstufe 3.1.1
        byte flags = 0x02; // Clean Session
        if (!string.IsNullOrEmpty(settings.Username)) flags |= 0x80;
        if (!string.IsNullOrEmpty(settings.Username) && settings.Password is not null) flags |= 0x40;
        body.Add(flags);
        AppendUInt16(body, (ushort)_keepAliveSeconds);
        AppendString(body, settings.ClientId);
        if ((flags & 0x80) != 0) AppendString(body, settings.Username!);
        if ((flags & 0x40) != 0) AppendString(body, settings.Password!);
        await WriteAsync(Connect, body, cancellationToken);

        var (header, response) = await ReadPacketAsync(cancellationToken);
        if ((header & 0xF0) != ConnAck || response.Length < 2) throw new MqttException("Broker antwortet nicht mit CONNACK.");
        var code = response[1];
        if (code != 0)
        {
            throw new MqttException(code switch
            {
                1 => "Broker unterstützt MQTT 3.1.1 nicht.",
                2 => "Client-ID abgelehnt.",
                3 => "Broker nicht verfügbar.",
                4 => "Benutzername oder Passwort falsch.",
                5 => "Keine Berechtigung.",
                _ => $"Verbindung abgelehnt (Code {code}).",
            });
        }
    }

    private async Task ReadLoopAsync()
    {
        var token = _lifetime.Token;
        try
        {
            while (!token.IsCancellationRequested)
            {
                var (header, body) = await ReadPacketAsync(token);
                Interlocked.Exchange(ref _lastReceivedTicks, Environment.TickCount64);
                switch (header & 0xF0)
                {
                    case Publish:
                        await HandlePublishAsync(header, body, token);
                        break;
                    case SubAck:
                        var id = BinaryPrimitives.ReadUInt16BigEndian(body);
                        TaskCompletionSource<byte[]>? pending;
                        lock (_pendingSubscriptions)
                        {
                            _pendingSubscriptions.Remove(id, out pending);
                        }
                        pending?.TrySetResult(body[2..]);
                        break;
                    case PubRel:
                        var relId = BinaryPrimitives.ReadUInt16BigEndian(body);
                        lock (_qos2InFlight) _qos2InFlight.Remove(relId);
                        await WriteAsync(PubComp, PacketId(relId), token);
                        break;
                    case PingResp:
                    default:
                        break;
                }
            }
        }
        catch (Exception) when (token.IsCancellationRequested)
        {
            // Regulär getrennt.
        }
        catch (Exception error)
        {
            _messages.Writer.TryComplete(error);
            FailPending(error);
            throw;
        }
        finally
        {
            _messages.Writer.TryComplete();
            FailPending(new MqttException("Verbindung getrennt."));
            _lifetime.Cancel();
        }
    }

    private async Task HandlePublishAsync(byte header, byte[] body, CancellationToken token)
    {
        var qos = (header >> 1) & 0x03;
        var retain = (header & 0x01) != 0;
        var topicLength = BinaryPrimitives.ReadUInt16BigEndian(body);
        var topic = Encoding.UTF8.GetString(body, 2, topicLength);
        var offset = 2 + topicLength;
        ushort packetId = 0;
        if (qos > 0)
        {
            packetId = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(offset));
            offset += 2;
        }
        var payload = body[offset..];
        switch (qos)
        {
            case 1:
                await WriteAsync(PubAck, PacketId(packetId), token);
                break;
            case 2:
                bool isNew;
                lock (_qos2InFlight) isNew = _qos2InFlight.Add(packetId);
                await WriteAsync(PubRec, PacketId(packetId), token);
                if (!isNew) return; // Wiederholung, schon zugestellt.
                break;
        }
        await _messages.Writer.WriteAsync(new MqttMessage(topic, payload, qos, retain), token);
    }

    private async Task PingLoopAsync()
    {
        var token = _lifetime.Token;
        var interval = TimeSpan.FromSeconds(_keepAliveSeconds / 2.0);
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Task.Delay(interval, token);
                var silentMs = Environment.TickCount64 - Interlocked.Read(ref _lastReceivedTicks);
                if (silentMs > _keepAliveSeconds * 1500L)
                {
                    // Broker antwortet nicht mehr – Verbindung abbrechen, die Brücke verbindet neu.
                    _stream.Dispose();
                    return;
                }
                await WriteAsync(PingReq, [], token);
            }
        }
        catch
        {
            // Ende der Verbindung.
        }
    }

    private void FailPending(Exception error)
    {
        lock (_pendingSubscriptions)
        {
            foreach (var pending in _pendingSubscriptions.Values) pending.TrySetException(error);
            _pendingSubscriptions.Clear();
        }
    }

    // MARK: Pakete

    private async Task WriteAsync(byte header, List<byte> body, CancellationToken cancellationToken)
    {
        var packet = MqttCodec.Packet(header, body);
        await _writeGate.WaitAsync(cancellationToken);
        try
        {
            await _stream.WriteAsync(packet, cancellationToken);
            await _stream.FlushAsync(cancellationToken);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private async Task<(byte Header, byte[] Body)> ReadPacketAsync(CancellationToken cancellationToken)
    {
        var header = await ReadByteAsync(cancellationToken);
        var length = 0;
        var multiplier = 1;
        for (var i = 0; ; i++)
        {
            if (i == 4) throw new MqttException("Ungültige Paketlänge.");
            var digit = await ReadByteAsync(cancellationToken);
            length += (digit & 0x7F) * multiplier;
            if ((digit & 0x80) == 0) break;
            multiplier *= 128;
        }
        var body = new byte[length];
        if (length > 0) await _stream.ReadExactlyAsync(body, cancellationToken);
        return (header, body);
    }

    private async Task<byte> ReadByteAsync(CancellationToken cancellationToken)
    {
        await _stream.ReadExactlyAsync(_oneByte, cancellationToken);
        return _oneByte[0];
    }

    private ushort NextPacketId()
    {
        lock (_pendingSubscriptions)
        {
            _nextPacketId = (ushort)(_nextPacketId == ushort.MaxValue ? 1 : _nextPacketId + 1);
            return _nextPacketId;
        }
    }

    private static List<byte> PacketId(ushort id)
    {
        var body = new List<byte>(2);
        AppendUInt16(body, id);
        return body;
    }

    private static void AppendUInt16(List<byte> target, ushort value)
    {
        target.Add((byte)(value >> 8));
        target.Add((byte)(value & 0xFF));
    }

    private static void AppendString(List<byte> target, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > ushort.MaxValue) throw new MqttException("Text zu lang.");
        AppendUInt16(target, (ushort)bytes.Length);
        target.AddRange(bytes);
    }
}

/// <summary>Kodierung des festen Kopfes (getrennt, damit testbar).</summary>
public static class MqttCodec
{
    public static byte[] Packet(byte header, IReadOnlyCollection<byte> body)
    {
        var length = EncodeRemainingLength(body.Count);
        var packet = new byte[1 + length.Length + body.Count];
        packet[0] = header;
        length.CopyTo(packet, 1);
        var index = 1 + length.Length;
        foreach (var b in body) packet[index++] = b;
        return packet;
    }

    public static byte[] EncodeRemainingLength(int length)
    {
        if (length is < 0 or > 268_435_455) throw new MqttException("Nachricht zu groß.");
        var bytes = new List<byte>(4);
        do
        {
            var digit = (byte)(length % 128);
            length /= 128;
            if (length > 0) digit |= 0x80;
            bytes.Add(digit);
        } while (length > 0);
        return [.. bytes];
    }
}
