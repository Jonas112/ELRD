using System.Text;
using System.Text.Json.Nodes;
using ElrdBackend.Alamos;
using ElrdBackend.Debug;
using ElrdBackend.Storage;
using Microsoft.Extensions.Logging.Abstractions;

namespace ElrdBackend.Tests;

public static class IngestTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 11, 18, 0, 0, TimeSpan.Zero);

    private static (AlarmIngest Ingest, DataStore Store, ManualTime Time, TempStore Temp) Make()
    {
        var temp = new TempStore();
        var store = temp.Open();
        var time = new ManualTime(Start);
        return (new AlarmIngest(store, time, NullLogger<AlarmIngest>.Instance), store, time, temp);
    }

    private static byte[] Bytes(string json) => Encoding.UTF8.GetBytes(json);

    private const string Alarm = """
        {"type":"ALARM","timestamp":"2026-11-11T19:00:00+01:00","sender":"ILS","data":{
          "externalId":"4711","keyword":"RD 2","keyword_description":"VU","message":["Zeile 1"],
          "location":{"coordinate":[10.2,50.05],"street":"Markt","city":"Schweinfurt"}}}
        """;

    public static void NeuerEinsatzWirdAngelegt()
    {
        var (ingest, store, _, temp) = Make();
        using var _ = temp;
        var result = ingest.Ingest("org", Bytes(Alarm), "mqtt");
        Assert.Equal(IngestOutcome.Created, result.Outcome);
        var alarm = Assert.NotNull(result.Alarm);
        Assert.Equal("4711", alarm.ExternalId);
        Assert.Equal(1, alarm.Revision);
        Assert.Equal("ILS", alarm.Sender);
        Assert.Equal("RD 2", alarm.Data["keyword"]!.GetValue<string>());
        Assert.Equal(1, store.Read(s => s.Alarms.Count));
    }

    public static void GleicherInhaltZaehltNicht()
    {
        var (ingest, _, _, temp) = Make();
        using var _ = temp;
        ingest.Ingest("org", Bytes(Alarm), "mqtt");
        var again = ingest.Ingest("org", Bytes(Alarm), "mqtt");
        Assert.Equal(IngestOutcome.Unchanged, again.Outcome);
        Assert.Equal(1, again.Alarm!.Revision);
    }

    public static void AktualisierungErhoehtStand()
    {
        var (ingest, store, time, temp) = Make();
        using var _ = temp;
        ingest.Ingest("org", Bytes(Alarm), "mqtt");
        time.Advance(TimeSpan.FromMinutes(3));
        var result = ingest.Ingest("org", Bytes(Alarm.Replace("RD 2", "RD 3")), "mqtt");
        Assert.Equal(IngestOutcome.Updated, result.Outcome);
        Assert.Equal(2, result.Alarm!.Revision);
        Assert.Equal(Start.AddMinutes(3), result.Alarm.UpdatedAt);
        Assert.Equal(Start, result.Alarm.ReceivedAt);
        Assert.Equal(1, store.Read(s => s.Alarms.Count));
    }

    public static void GleicheNummerAndereOrganisationIstEigenerEinsatz()
    {
        var (ingest, store, _, temp) = Make();
        using var _ = temp;
        ingest.Ingest("a", Bytes(Alarm), "mqtt");
        ingest.Ingest("b", Bytes(Alarm), "mqtt");
        Assert.Equal(2, store.Read(s => s.Alarms.Count));
    }

    public static void CloseSchliesstUndNeueDatenOeffnen()
    {
        var (ingest, _, _, temp) = Make();
        using var _ = temp;
        ingest.Ingest("org", Bytes(Alarm), "mqtt");
        var closed = ingest.Ingest("org", Bytes("""{"type":"CLOSE","data":{"externalId":"4711"}}"""), "mqtt");
        Assert.Equal(IngestOutcome.Closed, closed.Outcome);
        Assert.True(closed.Alarm!.ClosedAt is not null);
        Assert.Equal(IngestOutcome.Unchanged, ingest.Ingest("org", Bytes("""{"type":"CLOSE","data":{"externalId":"4711"}}"""), "mqtt").Outcome);
        var reopened = ingest.Ingest("org", Bytes(Alarm), "mqtt");
        Assert.Equal(IngestOutcome.Updated, reopened.Outcome);
        Assert.True(reopened.Alarm!.ClosedAt is null);
    }

    public static void StatusWirdIgnoriert()
    {
        var (ingest, store, _, temp) = Make();
        using var _ = temp;
        var result = ingest.Ingest("org", Bytes("""{"type":"STATUS","data":{"status":"3","radioName":"RK SWFT 71/1"}}"""), "mqtt");
        Assert.Equal(IngestOutcome.Ignored, result.Outcome);
        Assert.Equal(0, store.Read(s => s.Alarms.Count));
    }

    public static void KeinJsonWirdAbgelehnt()
    {
        var (ingest, _, _, temp) = Make();
        using var _ = temp;
        var result = ingest.Ingest("org", Bytes("U2FsdGVkX1+verschlüsselt"), "mqtt");
        Assert.Equal(IngestOutcome.Rejected, result.Outcome);
        Assert.True(result.Message.Contains("Verschlüsselung"));
    }

    public static void OhneUmschlagIstObjektDasDataObjekt()
    {
        var (ingest, _, _, temp) = Make();
        using var _ = temp;
        var result = ingest.Ingest("org", Bytes("""{"externalId":"99","keyword":"RD 1"}"""), "mqtt");
        Assert.Equal(IngestOutcome.Created, result.Outcome);
        Assert.Equal("99", result.Alarm!.ExternalId);
    }

    public static void JsonAlsZeichenketteWirdAusgepackt()
    {
        var (ingest, _, _, temp) = Make();
        using var _ = temp;
        var wrapped = JsonValue.Create(Alarm)!.ToJsonString();
        var result = ingest.Ingest("org", Bytes(wrapped), "mqtt");
        Assert.Equal(IngestOutcome.Created, result.Outcome);
    }

    public static void ZahlAlsEinsatznummer()
    {
        var (ingest, _, _, temp) = Make();
        using var _ = temp;
        var result = ingest.Ingest("org", Bytes("""{"type":"ALARM","data":{"externalId":12345,"keyword":"RD 1"}}"""), "mqtt");
        Assert.Equal("12345", result.Alarm!.ExternalId);
    }

    public static void OhneEinsatznummerJedesMalNeu()
    {
        var (ingest, store, _, temp) = Make();
        using var _ = temp;
        var json = """{"type":"ALARM","data":{"keyword":"RD 1"}}""";
        var first = ingest.Ingest("org", Bytes(json), "mqtt");
        ingest.Ingest("org", Bytes(json), "mqtt");
        Assert.True(first.Alarm!.ExternalId.StartsWith("elrd-"));
        Assert.Equal(first.Alarm.ExternalId, first.Alarm.Data["externalId"]!.GetValue<string>());
        Assert.Equal(2, store.Read(s => s.Alarms.Count));
    }

    public static void ZuGrossWirdAbgelehnt()
    {
        var (ingest, _, _, temp) = Make();
        using var _ = temp;
        var result = ingest.Ingest("org", new byte[AlarmIngest.MaxPayloadBytes + 1], "mqtt");
        Assert.Equal(IngestOutcome.Rejected, result.Outcome);
    }

    public static void VorlagenSindGueltigUndAlsTestMarkiert()
    {
        var (ingest, _, time, temp) = Make();
        using var _ = temp;
        foreach (var sample in SampleAlarms.All)
        {
            var envelope = SampleAlarms.Create(sample.Id, time.GetUtcNow());
            var result = ingest.Ingest("org", Bytes(envelope.ToJsonString()), "mqtt");
            Assert.Equal(IngestOutcome.Created, result.Outcome);
            Assert.True(result.Alarm!.IsTest, sample.Id);
            Assert.Equal(sample.Keyword, result.Alarm.Data["keyword"]!.GetValue<string>());
            var coordinate = result.Alarm.Data["location"]!["coordinate"]!.AsArray();
            // Längengrad zuerst (Deutschland: ~6–15° O, ~47–55° N).
            Assert.True(coordinate[0]!.GetValue<double>() < 16 && coordinate[1]!.GetValue<double>() > 46, sample.Id);
            time.Advance(TimeSpan.FromSeconds(1));
        }
    }

    public static void SimulierteAenderungenKommenAlsAktualisierung()
    {
        var (ingest, _, time, temp) = Make();
        using var _ = temp;
        var created = ingest.Ingest("org", Bytes(SampleAlarms.Create("vu", time.GetUtcNow()).ToJsonString()), "debug").Alarm!;
        foreach (var change in SampleAlarms.Changes.Where(c => c.Id != "close"))
        {
            time.Advance(TimeSpan.FromMinutes(1));
            var current = ingest.Ingest("org", Bytes(SampleAlarms.Change(created, change.Id, time.GetUtcNow()).ToJsonString()), "debug");
            Assert.Equal(IngestOutcome.Updated, current.Outcome);
            created = current.Alarm!;
        }
        Assert.Equal("RD 3", created.Data["keyword"]!.GetValue<string>());
        Assert.Equal(3, created.Data["vehicles"]!.AsArray().Count);
        Assert.Equal(2, created.Data["patient"]!.AsArray().Count);
        var closed = ingest.Ingest("org", Bytes(SampleAlarms.Change(created, "close", time.GetUtcNow()).ToJsonString()), "debug");
        Assert.Equal(IngestOutcome.Closed, closed.Outcome);
    }

    public static void StichwortErhoehen()
    {
        Assert.Equal("RD 3", SampleAlarms.RaiseKeyword("RD 2"));
        Assert.Equal("MANV 11", SampleAlarms.RaiseKeyword("MANV 10"));
        Assert.Equal("B 4 Person", SampleAlarms.RaiseKeyword("B 3 Person"));
        Assert.Equal("THL +", SampleAlarms.RaiseKeyword("THL"));
    }
}
