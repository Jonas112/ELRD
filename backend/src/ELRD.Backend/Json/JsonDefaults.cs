using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ElrdBackend.Json;

/// <summary>Gemeinsame JSON-Einstellungen für Datei und API.</summary>
public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = Configure(new JsonSerializerOptions(JsonSerializerDefaults.Web));

    /// <summary>camelCase, Nullwerte weglassen, Zeitpunkte als UTC mit Millisekunden.</summary>
    public static JsonSerializerOptions Configure(JsonSerializerOptions options)
    {
        options.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
        options.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
        if (!options.Converters.OfType<UtcDateTimeOffsetConverter>().Any())
        {
            options.Converters.Add(new UtcDateTimeOffsetConverter());
        }
        return options;
    }
}

/// <summary>
/// Schreibt Zeitpunkte immer als <c>2026-11-11T18:30:00.123Z</c> – das liest
/// <c>ISO8601DateFormatter</c> in der App ohne Sonderfälle. Lesen akzeptiert jede ISO-Form.
/// </summary>
public sealed class UtcDateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    public const string Format = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var text = reader.GetString() ?? throw new JsonException("Zeitpunkt fehlt.");
        return DateTimeOffset.Parse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value.ToUniversalTime().ToString(Format, CultureInfo.InvariantCulture));
    }
}
