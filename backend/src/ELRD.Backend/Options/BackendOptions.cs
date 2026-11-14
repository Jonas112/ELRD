namespace ElrdBackend.Options;

/// <summary>Einstellungen aus appsettings.json bzw. Umgebungsvariablen (z. B. <c>Mqtt__Host</c>).</summary>
public sealed class BackendOptions
{
    public const string SectionName = "Elrd";

    public MqttOptions Mqtt { get; set; } = new();
    public StorageOptions Storage { get; set; } = new();
    public AdminOptions Admin { get; set; } = new();
    public DebugOptions Debug { get; set; } = new();
    public RetentionOptions Retention { get; set; } = new();
    public PushOptions Push { get; set; } = new();
}

/// <summary>
/// Schritt 144: Push-Mitteilungen über Apple (APNs) bei neuen Einsätzen. Schlüssel aus dem
/// Apple-Developer-Konto (Keys › „Apple Push Notifications service“, .p8-Datei).
/// </summary>
public sealed class PushOptions
{
    public bool Enabled { get; set; }
    public string? TeamId { get; set; }
    public string? KeyId { get; set; }
    /// <summary>Pfad zur .p8-Datei …</summary>
    public string? KeyFile { get; set; }
    /// <summary>… oder ihr Inhalt (z. B. als Umgebungsvariable <c>Elrd__Push__Key</c>).</summary>
    public string? Key { get; set; }
    public string BundleId { get; set; } = "ELRD.App";
    /// <summary>Auch bei Testeinsätzen (Debug-Seite, Testskript) melden.</summary>
    public bool IncludeTests { get; set; } = true;
    /// <summary>Nur für Tests: andere Adresse statt Apple.</summary>
    public string? HostOverride { get; set; }
}

public sealed class MqttOptions
{
    /// <summary>Verbindung zum Broker aufbauen (aus: nur HTTP-Debug-Eingang).</summary>
    public bool Enabled { get; set; }
    public string Host { get; set; } = "localhost";
    /// <summary>8883 mit TLS, 1883 ohne.</summary>
    public int Port { get; set; } = 8883;
    public bool UseTls { get; set; } = true;
    /// <summary>Nur zum Testen mit selbst signierten Zertifikaten.</summary>
    public bool AllowUntrustedCertificates { get; set; }
    public string? Username { get; set; }
    public string? Password { get; set; }
    public string ClientId { get; set; } = "elrd-backend";
    /// <summary>Topics: <c>{TopicPrefix}/{organisation}/alarm</c>.</summary>
    public string TopicPrefix { get; set; } = "elrd";
    public int KeepAliveSeconds { get; set; } = 30;
}

public sealed class StorageOptions
{
    /// <summary>Ordner für <c>store.json</c>. Relativ zum Arbeitsverzeichnis.</summary>
    public string DataDirectory { get; set; } = "data";
    /// <summary>
    /// Optional: 32-Byte-Schlüssel (Base64). Dann wird die Datei mit AES-GCM
    /// verschlüsselt gespeichert. Erzeugen z. B. mit <c>openssl rand -base64 32</c>.
    /// </summary>
    public string? EncryptionKey { get; set; }
}

public sealed class AdminOptions
{
    /// <summary>
    /// Schlüssel für Verwaltung und Debug-Seite (Kopfzeile <c>X-Admin-Key</c>).
    /// Leer = Verwaltung gesperrt. Mindestens 16 Zeichen.
    /// </summary>
    public string? Key { get; set; }
}

public sealed class DebugOptions
{
    /// <summary>Testeinsätze anlegen und Änderungen simulieren (nur mit Admin-Schlüssel).</summary>
    public bool Enabled { get; set; }
}

public sealed class RetentionOptions
{
    /// <summary>Einsätze werden so viele Stunden nach der letzten Änderung gelöscht.</summary>
    public int Hours { get; set; } = 24;
}
