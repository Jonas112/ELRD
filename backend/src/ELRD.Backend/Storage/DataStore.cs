using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using ElrdBackend.Json;
using ElrdBackend.Options;
using Microsoft.Extensions.Options;

namespace ElrdBackend.Storage;

/// <summary>
/// Kleiner Speicher im Arbeitsspeicher, nach jeder Änderung als Datei gesichert
/// (atomar über Zwischendatei). Für eine „Datenschublade“ mit kurzer Aufbewahrung
/// reicht das; es braucht weder Datenbank noch NuGet-Paket (E123).
/// </summary>
public sealed class DataStore
{
    private static readonly byte[] EncryptedMagic = "ELRDENC1"u8.ToArray();
    private readonly Lock _gate = new();
    private readonly string _path;
    private readonly byte[]? _key;
    private readonly ILogger<DataStore> _logger;
    private StoreState _state;

    public DataStore(IOptions<BackendOptions> options, ILogger<DataStore> logger)
    {
        _logger = logger;
        var storage = options.Value.Storage;
        Directory.CreateDirectory(storage.DataDirectory);
        _path = Path.Combine(storage.DataDirectory, "store.json");
        _key = ParseKey(storage.EncryptionKey);
        _state = Load();
    }

    /// <summary>Liest unter Sperre (Ergebnis darf den Zustand nicht nach außen geben – Kopien liefern).</summary>
    public T Read<T>(Func<StoreState, T> read)
    {
        lock (_gate) return read(_state);
    }

    /// <summary>Ändert unter Sperre und speichert sofort.</summary>
    public T Write<T>(Func<StoreState, T> change)
    {
        lock (_gate)
        {
            var result = change(_state);
            Save();
            return result;
        }
    }

    /// <summary>Tiefe Kopie, damit Aufrufer außerhalb der Sperre damit arbeiten können.</summary>
    public static StoredAlarm Copy(StoredAlarm alarm) => new()
    {
        Id = alarm.Id,
        OrganisationId = alarm.OrganisationId,
        ExternalId = alarm.ExternalId,
        Revision = alarm.Revision,
        Sender = alarm.Sender,
        ReceivedAt = alarm.ReceivedAt,
        UpdatedAt = alarm.UpdatedAt,
        ClosedAt = alarm.ClosedAt,
        Source = alarm.Source,
        IsTest = alarm.IsTest,
        Data = (JsonObject)alarm.Data.DeepClone(),
    };

    public static Organisation Copy(Organisation organisation) => new()
    {
        Id = organisation.Id,
        Name = organisation.Name,
        ApiKeyHash = organisation.ApiKeyHash,
        ApiKeyHint = organisation.ApiKeyHint,
        CreatedAt = organisation.CreatedAt,
    };

    private StoreState Load()
    {
        if (!File.Exists(_path)) return new StoreState();
        var bytes = File.ReadAllBytes(_path);
        if (bytes.AsSpan().StartsWith(EncryptedMagic))
        {
            if (_key is null) throw new InvalidOperationException("store.json ist verschlüsselt, aber Elrd:Storage:EncryptionKey fehlt.");
            bytes = Decrypt(bytes, _key);
        }
        else if (_key is not null)
        {
            _logger.LogInformation("store.json war unverschlüsselt und wird beim nächsten Speichern verschlüsselt.");
        }
        return JsonSerializer.Deserialize<StoreState>(bytes, JsonDefaults.Options) ?? new StoreState();
    }

    private void Save()
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(_state, JsonDefaults.Options);
        if (_key is not null) bytes = Encrypt(bytes, _key);
        var temporary = _path + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, _path, overwrite: true);
    }

    private static byte[]? ParseKey(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var key = Convert.FromBase64String(text.Trim());
        if (key.Length != 32) throw new InvalidOperationException("Elrd:Storage:EncryptionKey muss 32 Byte (Base64) lang sein.");
        return key;
    }

    // Aufbau: Magic (8) | Nonce (12) | Tag (16) | Chiffrat
    private static byte[] Encrypt(byte[] plain, byte[] key)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        var tag = new byte[16];
        var cipher = new byte[plain.Length];
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(nonce, plain, cipher, tag);
        return [.. EncryptedMagic, .. nonce, .. tag, .. cipher];
    }

    private static byte[] Decrypt(byte[] data, byte[] key)
    {
        var offset = EncryptedMagic.Length;
        var nonce = data.AsSpan(offset, 12);
        var tag = data.AsSpan(offset + 12, 16);
        var cipher = data.AsSpan(offset + 28);
        var plain = new byte[cipher.Length];
        using var aes = new AesGcm(key, 16);
        aes.Decrypt(nonce, cipher, tag, plain);
        return plain;
    }
}
