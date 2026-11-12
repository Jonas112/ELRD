using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using ElrdBackend.Storage;

namespace ElrdBackend.Security;

/// <summary>Organisationen anlegen und App-Schlüssel prüfen. Schlüssel werden nur als SHA-256 gespeichert.</summary>
public sealed partial class Organisations(DataStore store, TimeProvider time)
{
    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,39}$")]
    private static partial Regex IdPattern();

    public static bool IsValidId(string id) => IdPattern().IsMatch(id);

    public IReadOnlyList<Organisation> All() =>
        store.Read(state => state.Organisations.Select(DataStore.Copy).OrderBy(o => o.Name).ToList());

    public bool Exists(string id) => store.Read(state => state.Organisations.Any(o => o.Id == id));

    /// <summary>Legt an und liefert den Schlüssel im Klartext – nur dieses eine Mal.</summary>
    public (Organisation Organisation, string ApiKey) Create(string id, string name)
    {
        id = id.Trim().ToLowerInvariant();
        name = name.Trim();
        if (!IsValidId(id)) throw new ArgumentException("Kennung: 2–40 Zeichen, nur a–z, 0–9 und „-“.");
        if (name.Length == 0) throw new ArgumentException("Bitte einen Namen angeben.");
        var key = NewKey();
        var organisation = new Organisation
        {
            Id = id,
            Name = name,
            ApiKeyHash = Hash(key),
            ApiKeyHint = key[^4..],
            CreatedAt = time.GetUtcNow(),
        };
        store.Write(state =>
        {
            if (state.Organisations.Any(o => o.Id == id)) throw new ArgumentException($"Kennung „{id}“ gibt es schon.");
            state.Organisations.Add(organisation);
            return 0;
        });
        return (DataStore.Copy(organisation), key);
    }

    /// <summary>Neuer Schlüssel; der alte gilt sofort nicht mehr.</summary>
    public string? RenewKey(string id)
    {
        var key = NewKey();
        var found = store.Write(state =>
        {
            var organisation = state.Organisations.FirstOrDefault(o => o.Id == id);
            if (organisation is null) return false;
            organisation.ApiKeyHash = Hash(key);
            organisation.ApiKeyHint = key[^4..];
            return true;
        });
        return found ? key : null;
    }

    /// <summary>Löscht die Organisation samt ihrer Einsätze.</summary>
    public bool Delete(string id) => store.Write(state =>
    {
        var removed = state.Organisations.RemoveAll(o => o.Id == id) > 0;
        state.Alarms.RemoveAll(a => a.OrganisationId == id);
        return removed;
    });

    /// <summary>Organisation zum Schlüssel oder <c>null</c>.</summary>
    public Organisation? Authenticate(string? key)
    {
        if (string.IsNullOrWhiteSpace(key)) return null;
        var hash = Convert.FromBase64String(Hash(key.Trim()));
        return store.Read(state =>
        {
            foreach (var organisation in state.Organisations)
            {
                var stored = Convert.FromBase64String(organisation.ApiKeyHash);
                if (CryptographicOperations.FixedTimeEquals(stored, hash)) return DataStore.Copy(organisation);
            }
            return null;
        });
    }

    /// <summary>40 Zeichen aus 30 Zufallsbytes, URL-sicher.</summary>
    internal static string NewKey() =>
        "elrd_" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(30)).Replace('+', '-').Replace('/', '_');

    internal static string Hash(string key) => Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(key)));
}
