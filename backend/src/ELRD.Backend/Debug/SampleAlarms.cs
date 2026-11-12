using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ElrdBackend.Storage;

namespace ElrdBackend.Debug;

public sealed record SampleInfo(string Id, string Title, string Keyword);

public sealed record ChangeInfo(string Id, string Title);

/// <summary>
/// Testeinsätze im Datenformat V2 (wie das FE2-JSON-Plugin sie erzeugt) und
/// simulierte Änderungen. Alle Angaben sind erfunden; Funkrufnamen stammen aus den
/// mitgelieferten Stammdaten (Schweinfurt), damit die App sie zuordnen kann.
/// Testeinsätze tragen <c>custom.elrdTest = "true"</c>.
/// </summary>
public static partial class SampleAlarms
{
    public const string TestMarker = "elrdTest";

    public static readonly IReadOnlyList<SampleInfo> All =
    [
        new("vu", "VU, eine Person eingeklemmt", "RD 2"),
        new("intern", "Bewusstlose Person", "RD 1"),
        new("pflegeheim", "Brand Pflegeheim, mehrere Betroffene", "RD 3"),
        new("bus", "Busunfall, MANV", "RD 4"),
    ];

    public static readonly IReadOnlyList<ChangeInfo> Changes =
    [
        new("keyword", "Stichwort erhöhen"),
        new("patient", "Patient hinzufügen"),
        new("vehicle", "Fahrzeug nachalarmieren"),
        new("message", "Nachmeldung (Text)"),
        new("location", "Einsatzort korrigieren"),
        new("close", "Einsatz schließen (CLOSE)"),
    ];

    private static readonly string[] VehiclePool =
    [
        "RK SWFT 71/1", "RK SWFT 71/2", "RK SWFT 71/20", "RK SWFT 76/1", "RK SWFT 76/2",
        "JOH SWFT 71/1", "JOH SWFT 71/2", "JOH SWFT 76/1", "SAMA SWFT 71/1", "AK SWFT 71/1",
        "RK WRNCK 71/1", "RK GEOHN 71/1", "RK SWFT 72/1", "RK SWFT 72/2",
    ];

    /// <summary>Neuer Testeinsatz mit frischer Einsatznummer.</summary>
    public static JsonObject Create(string sampleId, DateTimeOffset now, Random? random = null)
    {
        random ??= Random.Shared;
        var externalId = $"T{now:yyMMdd}-{now:HHmmss}-{random.Next(100, 999)}";
        var data = sampleId switch
        {
            "vu" => Data(externalId, "RD 2", "VU Pkw gegen Baum, 1 Person eingeklemmt",
                ["Pkw gegen Baum, Fahrer eingeklemmt, ansprechbar.", "FF Schweinfurt alarmiert."],
                Location("Niederwerrner Straße", "100", "97421", "Schweinfurt", 10.2165, 50.0546),
                ["RK SWFT 71/1", "RK SWFT 76/1"], now,
                [Patient("eingeklemmt, ansprechbar, Schmerzen Becken", null)]),
            "intern" => Data(externalId, "RD 1", "Bewusstlose Person",
                ["Person liegt bewusstlos im Treppenhaus, Atmung vorhanden."],
                Location("Markt", "1", "97421", "Schweinfurt", 10.2341, 50.0494),
                ["RK SWFT 71/2"], now, []),
            "pflegeheim" => Data(externalId, "RD 3", "Brand im Pflegeheim, mehrere Betroffene",
                ["Rauchentwicklung 2. OG, Bewohner werden evakuiert.", "Bereitstellungsraum Parkplatz Süd."],
                Location("Rügshöfer Straße", "20", "97447", "Gerolzhofen", 10.3466, 49.9011),
                ["RK SWFT 71/20", "SAMA SWFT 71/1", "RK GEOHN 71/1", "RK SWFT 76/2"], now,
                [Patient("Rauchgasexposition, Husten", null), Patient("gehfähig, Atemnot", null)]),
            "bus" => Data(externalId, "RD 4", "VU Reisebus, mehrere Verletzte (MANV)",
                ["Reisebus auf Seite, ca. 20 Insassen.", "Zufahrt über AS Schweinfurt/Werneck."],
                Location("A 70", null, "97440", "Werneck", 10.1003, 49.9811),
                ["RK SWFT 71/1", "JOH SWFT 71/1", "RK WRNCK 71/1", "RK SWFT 76/1", "JOH SWFT 76/1"], now,
                [Patient("eingeklemmt, Bein deformiert", null), Patient("Kopfplatzwunde, gehfähig", null), Patient("Thoraxschmerz, blass", null)]),
            _ => throw new ArgumentException($"Unbekannte Vorlage „{sampleId}“."),
        };
        data["caller"] = new JsonObject { ["name"] = "Testanrufer", ["contact"] = "0000 000000" };
        return Envelope("ALARM", now, data);
    }

    /// <summary>Simulierte Änderung an einem gespeicherten Einsatz – als komplette V2-Nachricht.</summary>
    public static JsonObject Change(StoredAlarm alarm, string change, DateTimeOffset now)
    {
        var data = (JsonObject)alarm.Data.DeepClone();
        switch (change)
        {
            case "keyword":
                var keyword = data["keyword"]?.GetValue<string>() ?? "RD 1";
                var raised = RaiseKeyword(keyword);
                data["keyword"] = raised;
                AddMessage(data, $"Stichworterhöhung {keyword} → {raised}", now);
                break;
            case "patient":
                var patients = data["patient"] as JsonArray ?? [];
                data["patient"] = patients;
                patients.Add(Patient("weiterer Patient (Simulation)", patients.Count + 1));
                AddMessage(data, "Weiterer Patient gemeldet", now);
                break;
            case "vehicle":
                var vehicles = data["vehicles"] as JsonArray ?? [];
                data["vehicles"] = vehicles;
                var used = vehicles.Select(v => v?["radioName"]?.GetValue<string>()).ToHashSet();
                var next = VehiclePool.FirstOrDefault(v => !used.Contains(v)) ?? $"RK SWFT 71/{vehicles.Count + 30}";
                vehicles.Add(Vehicle(next, now));
                AddMessage(data, $"Nachalarmierung {next}", now);
                break;
            case "message":
                AddMessage(data, "Nachmeldung der Leitstelle (Simulation)", now);
                break;
            case "location":
                if (data["location"] is JsonObject location)
                {
                    if (location["coordinate"] is JsonArray { Count: 2 } coordinate)
                    {
                        location["coordinate"] = new JsonArray(coordinate[0]!.GetValue<double>() + 0.0015, coordinate[1]!.GetValue<double>() + 0.0008);
                    }
                    location["additional"] = "Zufahrt über Hinterhof";
                }
                AddMessage(data, "Einsatzort korrigiert", now);
                break;
            case "close":
                return Envelope("CLOSE", now, new JsonObject { ["externalId"] = alarm.ExternalId });
            default:
                throw new ArgumentException($"Unbekannte Änderung „{change}“.");
        }
        return Envelope("ALARM", now, data);
    }

    /// <summary>„RD 2“ → „RD 3“; ohne Zahl wird „ +“ angehängt.</summary>
    public static string RaiseKeyword(string keyword)
    {
        var match = TrailingNumber().Match(keyword);
        if (!match.Success) return keyword + " +";
        var number = int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture) + 1;
        return match.Groups[1].Value + number.ToString(CultureInfo.InvariantCulture) + match.Groups[3].Value;
    }

    [GeneratedRegex(@"^(.*?)(\d+)(\D*)$")]
    private static partial Regex TrailingNumber();

    private static JsonObject Envelope(string type, DateTimeOffset now, JsonObject data) => new()
    {
        ["type"] = type,
        ["timestamp"] = now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture),
        ["sender"] = "ELRD-Debug",
        ["data"] = data,
    };

    private static JsonObject Data(
        string externalId, string keyword, string description, string[] message, JsonObject location,
        string[] vehicles, DateTimeOffset now, JsonObject[] patients)
    {
        var data = new JsonObject
        {
            ["externalId"] = externalId,
            ["keyword"] = keyword,
            ["keyword_description"] = description,
            ["message"] = new JsonArray([.. message.Select(m => JsonValue.Create(m))]),
            ["location"] = location,
            ["units"] = new JsonArray(new JsonObject { ["address"] = "ELRD" }),
            ["vehicles"] = new JsonArray([.. vehicles.Select(v => Vehicle(v, now))]),
            ["custom"] = new JsonObject { [TestMarker] = "true" },
        };
        if (patients.Length > 0)
        {
            for (var i = 0; i < patients.Length; i++) patients[i]["patientNumber"] = (i + 1).ToString(CultureInfo.InvariantCulture);
            data["patient"] = new JsonArray([.. patients]);
        }
        return data;
    }

    private static JsonObject Location(string street, string? house, string postalCode, string city, double longitude, double latitude)
    {
        var location = new JsonObject
        {
            // Reihenfolge laut Alamos: erst Längengrad, dann Breitengrad.
            ["coordinate"] = new JsonArray(longitude, latitude),
            ["street"] = street,
            ["postalCode"] = postalCode,
            ["city"] = city,
        };
        if (house is not null) location["house"] = house;
        return location;
    }

    private static JsonObject Vehicle(string radioName, DateTimeOffset now) => new()
    {
        ["id"] = radioName.Replace(" ", "").Replace("/", "-"),
        ["name"] = radioName,
        ["radioName"] = radioName,
        ["unitType"] = radioName.Contains(" 76/") ? "NEF" : radioName.Contains(" 72/") ? "KTW" : "RTW",
        ["station"] = radioName.Split(' ').Skip(1).FirstOrDefault() ?? "",
        ["alarmedTime"] = now.ToUnixTimeMilliseconds(),
    };

    private static JsonObject Patient(string remark, int? number)
    {
        var patient = new JsonObject { ["name"] = "", ["remark"] = remark };
        if (number is not null) patient["patientNumber"] = number.Value.ToString(CultureInfo.InvariantCulture);
        return patient;
    }

    private static readonly TimeZoneInfo Berlin = FindBerlin();

    private static TimeZoneInfo FindBerlin()
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin"); }
        catch (TimeZoneNotFoundException) { return TimeZoneInfo.Utc; }
    }

    private static void AddMessage(JsonObject data, string text, DateTimeOffset now)
    {
        var messages = data["message"] as JsonArray ?? [];
        data["message"] = messages;
        messages.Add($"{TimeZoneInfo.ConvertTime(now, Berlin):HH:mm} {text}");
    }
}
