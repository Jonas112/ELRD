using System.Text.Json.Nodes;

namespace ElrdBackend.Storage;

/// <summary>Organisation (Kunde), z. B. ein Rettungsdienstbereich. Kennung steht im MQTT-Topic.</summary>
public sealed class Organisation
{
    /// <summary>Kurzkennung, nur a–z, 0–9 und „-“ (z. B. „brk-schweinfurt“).</summary>
    public required string Id { get; set; }
    public required string Name { get; set; }
    /// <summary>SHA-256 des App-Schlüssels (Base64). Der Schlüssel selbst wird nie gespeichert.</summary>
    public required string ApiKeyHash { get; set; }
    /// <summary>Letzte vier Zeichen des Schlüssels zum Wiedererkennen.</summary>
    public string ApiKeyHint { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
}

/// <summary>Ein Einsatz aus Alamos FE2 – so, wie er zuletzt angekommen ist.</summary>
public sealed class StoredAlarm
{
    public Guid Id { get; set; }
    public required string OrganisationId { get; set; }
    /// <summary><c>data.externalId</c> aus FE2 (Einsatznummer); Aktualisierungen werden darüber zugeordnet.</summary>
    public required string ExternalId { get; set; }
    /// <summary>Zählt jede inhaltliche Änderung (1 = erste Meldung).</summary>
    public int Revision { get; set; }
    public string? Sender { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? ClosedAt { get; set; }
    /// <summary>Eingang: <c>mqtt</c>, <c>http</c> oder <c>debug</c>.</summary>
    public string Source { get; set; } = "mqtt";
    /// <summary>Von der Debug-Seite angelegt.</summary>
    public bool IsTest { get; set; }
    /// <summary>Das <c>data</c>-Objekt im Datenformat V2 der externen Schnittstelle, unverändert.</summary>
    public JsonObject Data { get; set; } = new();
}

/// <summary>Inhalt der Datei <c>store.json</c>.</summary>
public sealed class StoreState
{
    public int Version { get; set; } = 1;
    public List<Organisation> Organisations { get; set; } = [];
    public List<StoredAlarm> Alarms { get; set; } = [];
}
