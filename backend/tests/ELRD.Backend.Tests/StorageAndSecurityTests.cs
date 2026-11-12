using System.Security.Cryptography;
using System.Text.Json.Nodes;
using ElrdBackend.Mqtt;
using ElrdBackend.Security;
using ElrdBackend.Storage;
using Microsoft.Extensions.Logging.Abstractions;

namespace ElrdBackend.Tests;

public static class StorageAndSecurityTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 11, 18, 0, 0, TimeSpan.Zero);

    public static void SpeicherUeberstehtNeustart()
    {
        using var temp = new TempStore();
        temp.Open().Write(state =>
        {
            state.Alarms.Add(new StoredAlarm { OrganisationId = "org", ExternalId = "1", Data = new JsonObject { ["keyword"] = "RD 1" } });
            return 0;
        });
        var reopened = temp.Open();
        Assert.Equal("RD 1", reopened.Read(s => s.Alarms[0].Data["keyword"]!.GetValue<string>()));
    }

    public static void VerschluesselterSpeicher()
    {
        var key = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        using var temp = new TempStore(key);
        temp.Open().Write(state =>
        {
            state.Alarms.Add(new StoredAlarm { OrganisationId = "org", ExternalId = "geheim-4711", Data = [] });
            return 0;
        });
        var raw = File.ReadAllText(Path.Combine(temp.Directory, "store.json"));
        Assert.True(!raw.Contains("geheim-4711"), "Klartext in der Datei");
        Assert.Equal("geheim-4711", temp.Open().Read(s => s.Alarms[0].ExternalId));

        // Ohne Schlüssel nicht lesbar.
        temp.Options.Storage.EncryptionKey = null;
        Assert.Throws<InvalidOperationException>(() => temp.Open());
    }

    public static void OrganisationUndSchluessel()
    {
        using var temp = new TempStore();
        var organisations = new Organisations(temp.Open(), new ManualTime(Start));
        var (organisation, key) = organisations.Create("BRK-Schweinfurt", "BRK Schweinfurt");
        Assert.Equal("brk-schweinfurt", organisation.Id);
        Assert.True(key.StartsWith("elrd_") && key.Length >= 40);
        Assert.True(!organisation.ApiKeyHash.Contains(key));
        Assert.Equal("brk-schweinfurt", organisations.Authenticate(key)?.Id);
        Assert.True(organisations.Authenticate(key + "x") is null);
        Assert.True(organisations.Authenticate(null) is null);

        var renewed = Assert.NotNull(organisations.RenewKey("brk-schweinfurt"));
        Assert.True(organisations.Authenticate(key) is null, "alter Schlüssel gilt noch");
        Assert.Equal("brk-schweinfurt", organisations.Authenticate(renewed)?.Id);

        Assert.Throws<ArgumentException>(() => organisations.Create("brk-schweinfurt", "doppelt"));
        Assert.Throws<ArgumentException>(() => organisations.Create("ä/b", "ungültig"));
        Assert.Throws<ArgumentException>(() => organisations.Create("x", "zu kurz"));
    }

    public static void AufbewahrungLoeschtAlteEinsaetze()
    {
        using var temp = new TempStore();
        temp.Options.Retention.Hours = 24;
        var store = temp.Open();
        var time = new ManualTime(Start);
        store.Write(state =>
        {
            state.Alarms.Add(new StoredAlarm { OrganisationId = "o", ExternalId = "alt", UpdatedAt = Start.AddHours(-25) });
            state.Alarms.Add(new StoredAlarm { OrganisationId = "o", ExternalId = "neu", UpdatedAt = Start.AddHours(-1) });
            return 0;
        });
        var worker = new RetentionWorker(store, Microsoft.Extensions.Options.Options.Create(temp.Options), time, NullLogger<RetentionWorker>.Instance);
        Assert.Equal(1, worker.Purge());
        Assert.Equal("neu", store.Read(s => s.Alarms.Single().ExternalId));
    }

    public static void MqttRestlaenge()
    {
        Assert.Equal("00", Hex(MqttCodec.EncodeRemainingLength(0)));
        Assert.Equal("7F", Hex(MqttCodec.EncodeRemainingLength(127)));
        Assert.Equal("8001", Hex(MqttCodec.EncodeRemainingLength(128)));
        Assert.Equal("FF7F", Hex(MqttCodec.EncodeRemainingLength(16_383)));
        Assert.Equal("808001", Hex(MqttCodec.EncodeRemainingLength(16_384)));
        Assert.Equal("FFFFFF7F", Hex(MqttCodec.EncodeRemainingLength(268_435_455)));
        Assert.Throws<MqttException>(() => MqttCodec.EncodeRemainingLength(268_435_456));
        Assert.Equal("C000", Hex(MqttCodec.Packet(0xC0, Array.Empty<byte>())));
    }

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes);
}
