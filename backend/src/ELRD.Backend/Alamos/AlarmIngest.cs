using System.Text.Json;
using System.Text.Json.Nodes;
using ElrdBackend.Storage;

namespace ElrdBackend.Alamos;

public enum IngestOutcome
{
    Created,
    Updated,
    Closed,
    /// <summary>Gleicher Inhalt wie zuletzt (z. B. doppelt gesendet).</summary>
    Unchanged,
    /// <summary>Gültig, aber nicht verarbeitet (z. B. Fahrzeugstatus, E110).</summary>
    Ignored,
    Rejected,
}

public sealed record IngestResult(IngestOutcome Outcome, string Message, StoredAlarm? Alarm = null)
{
    public bool IsSuccess => Outcome is not IngestOutcome.Rejected;
}

/// <summary>
/// Nimmt Nachrichten im Datenformat V2 der externen Schnittstelle von Alamos FE2 an
/// (so erzeugt sie das JSON-Plugin) und legt sie in der Schublade ab.
///
/// Erkannt werden <c>type</c> = <c>ALARM</c> (neu oder Aktualisierung über
/// <c>data.externalId</c>), <c>CLOSE</c> und <c>STATUS</c> (wird ignoriert).
/// Fehlt der Umschlag, wird das ganze Objekt als <c>data</c> gelesen.
/// In die Protokolle kommen nur Kennungen, nie Einsatzinhalte.
/// </summary>
public sealed class AlarmIngest(DataStore store, TimeProvider time, ILogger<AlarmIngest> logger)
{
    public const int MaxPayloadBytes = 512 * 1024;

    /// <summary>Schritt 144: nach jeder verarbeiteten Nachricht (z. B. Push-Mitteilungen).</summary>
    public event Action<string, IngestResult>? Processed;

    public IngestResult Ingest(string organisationId, ReadOnlySpan<byte> payload, string source, bool isTest = false)
    {
        if (payload.Length > MaxPayloadBytes) return Reject(organisationId, "Nachricht ist größer als 512 KB.");
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(payload, documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true });
        }
        catch (JsonException)
        {
            return Reject(organisationId, "Kein gültiges JSON. Ist im JSON-Plugin eine Verschlüsselung (Passwort) gesetzt? Bitte leer lassen.");
        }
        // Manche Wege liefern das JSON als Zeichenkette (Alarmtext) – einmal auspacken.
        if (root is JsonValue value && value.TryGetValue<string>(out var inner))
        {
            try { root = JsonNode.Parse(inner); }
            catch (JsonException) { return Reject(organisationId, "Text enthält kein JSON."); }
        }
        if (root is not JsonObject envelope) return Reject(organisationId, "JSON-Objekt erwartet.");

        var type = (Text(envelope, "type") ?? "ALARM").Trim().ToUpperInvariant();
        var data = envelope["data"] as JsonObject;
        if (data is null && !envelope.ContainsKey("type"))
        {
            // Kein Umschlag: Objekt ist selbst das data-Objekt.
            data = envelope;
        }
        var sender = Text(envelope, "sender");

        return type switch
        {
            "ALARM" when data is not null => Upsert(organisationId, data, sender, source, isTest),
            "ALARM" => Reject(organisationId, "ALARM ohne data-Objekt."),
            "CLOSE" => Close(organisationId, data is null ? null : Text(data, "externalId")),
            "STATUS" => new IngestResult(IngestOutcome.Ignored, "Fahrzeugstatus wird nicht verarbeitet (E110)."),
            _ => new IngestResult(IngestOutcome.Ignored, $"Typ „{type}“ wird nicht verarbeitet."),
        };
    }

    private IngestResult Upsert(string organisationId, JsonObject data, string? sender, string source, bool isTest)
    {
        var now = time.GetUtcNow();
        var externalId = Text(data, "externalId");
        var stored = (JsonObject)data.DeepClone();
        isTest = isTest || (stored["custom"] as JsonObject)?[Debug.SampleAlarms.TestMarker]?.ToString() == "true";
        if (string.IsNullOrWhiteSpace(externalId))
        {
            // Ohne Kennung lässt sich keine Aktualisierung zuordnen – jede Meldung ist neu.
            externalId = "elrd-" + Guid.NewGuid().ToString("N")[..12];
            stored["externalId"] = externalId;
        }

        var result = store.Write(state =>
        {
            var existing = state.Alarms.FirstOrDefault(a => a.OrganisationId == organisationId && a.ExternalId == externalId);
            if (existing is null)
            {
                var alarm = new StoredAlarm
                {
                    Id = Guid.NewGuid(),
                    OrganisationId = organisationId,
                    ExternalId = externalId,
                    Revision = 1,
                    Sender = sender,
                    ReceivedAt = now,
                    UpdatedAt = now,
                    Source = source,
                    IsTest = isTest,
                    Data = stored,
                };
                state.Alarms.Add(alarm);
                return new IngestResult(IngestOutcome.Created, "Neuer Einsatz.", DataStore.Copy(alarm));
            }
            if (JsonNode.DeepEquals(existing.Data, stored) && existing.ClosedAt is null)
            {
                return new IngestResult(IngestOutcome.Unchanged, "Keine Änderung.", DataStore.Copy(existing));
            }
            existing.Data = stored;
            existing.Revision += 1;
            existing.UpdatedAt = now;
            existing.Sender = sender ?? existing.Sender;
            existing.Source = source;
            // Neue Alarmdaten zu einem geschlossenen Einsatz: wieder offen.
            existing.ClosedAt = null;
            return new IngestResult(IngestOutcome.Updated, $"Aktualisierung (Stand {existing.Revision}).", DataStore.Copy(existing));
        });
        Log(organisationId, result);
        return result;
    }

    private IngestResult Close(string organisationId, string? externalId)
    {
        if (string.IsNullOrWhiteSpace(externalId)) return Reject(organisationId, "CLOSE ohne data.externalId.");
        var now = time.GetUtcNow();
        var result = store.Write(state =>
        {
            var existing = state.Alarms.FirstOrDefault(a => a.OrganisationId == organisationId && a.ExternalId == externalId);
            if (existing is null) return new IngestResult(IngestOutcome.Ignored, "Einsatz zum Schließen nicht gefunden.");
            if (existing.ClosedAt is not null) return new IngestResult(IngestOutcome.Unchanged, "Schon geschlossen.", DataStore.Copy(existing));
            existing.ClosedAt = now;
            existing.UpdatedAt = now;
            existing.Revision += 1;
            return new IngestResult(IngestOutcome.Closed, "Einsatz geschlossen.", DataStore.Copy(existing));
        });
        Log(organisationId, result);
        return result;
    }

    private IngestResult Reject(string organisationId, string message)
    {
        logger.LogWarning("Nachricht für {Organisation} abgelehnt: {Reason}", organisationId, message);
        return new IngestResult(IngestOutcome.Rejected, message);
    }

    private void Log(string organisationId, IngestResult result)
    {
        logger.LogInformation(
            "{Organisation}: {Outcome} {AlarmId} (Stand {Revision})",
            organisationId, result.Outcome, result.Alarm?.Id, result.Alarm?.Revision);
        try
        {
            Processed?.Invoke(organisationId, result);
        }
        catch (Exception error)
        {
            // Der Eingang darf an der Nachverarbeitung nicht scheitern.
            logger.LogError(error, "Nachverarbeitung fehlgeschlagen");
        }
    }

    private static string? Text(JsonObject json, string name)
    {
        if (json[name] is not JsonValue value) return null;
        if (value.TryGetValue<string>(out var text)) return text;
        // Zahlen als Einsatznummer zulassen.
        return value.GetValueKind() == JsonValueKind.Number ? value.ToJsonString() : null;
    }
}
