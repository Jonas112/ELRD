import Foundation

/// Anbindung an Alamos FE2 über das ELRD-Backend (Schritt 140). Teil der
/// Geräteeinstellungen; der App-Schlüssel liegt nicht hier, sondern in der Keychain.
public struct AlamosSettings: Codable, Hashable, Sendable {
    /// Einsätze vom Backend abfragen und in der Einsatzliste zeigen.
    public var isEnabled: Bool = false
    /// Adresse des ELRD-Backends, z. B. `https://elrd.example.de`.
    public var backendURL: String = ""
    /// Abfrage alle … Sekunden, solange die App im Vordergrund ist.
    public var pollSeconds: Int = 30
    /// Beim Übernehmen standardmäßig Fahrzeuge bzw. gemeldete Patienten anlegen.
    public var importsVehicles: Bool = true
    public var importsPatients: Bool = true
    /// In FE2 geschlossene Einsätze weiter zeigen.
    public var showsClosed: Bool = false
    /// Testeinsätze (Debug-Seite, Testskript) zeigen.
    public var showsTests: Bool = true
    /// Name der Organisation laut Backend (beim Verbindungstest gemerkt).
    public var organisationName: String?

    public static let pollChoices = [15, 30, 60, 120]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlamosSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        backendURL = try container.decodeIfPresent(String.self, forKey: .backendURL) ?? defaults.backendURL
        pollSeconds = try container.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? defaults.pollSeconds
        importsVehicles = try container.decodeIfPresent(Bool.self, forKey: .importsVehicles) ?? defaults.importsVehicles
        importsPatients = try container.decodeIfPresent(Bool.self, forKey: .importsPatients) ?? defaults.importsPatients
        showsClosed = try container.decodeIfPresent(Bool.self, forKey: .showsClosed) ?? defaults.showsClosed
        showsTests = try container.decodeIfPresent(Bool.self, forKey: .showsTests) ?? defaults.showsTests
        organisationName = try container.decodeIfPresent(String.self, forKey: .organisationName)
    }

    /// Adresse als URL: ohne Schema wird `https://` ergänzt – bei einer IP-Adresse,
    /// `localhost`, `….local` oder einem Namen ohne Punkt aber `http://` (Backend im eigenen Netz, z. B. das
    /// Python-Backend auf dem Mac). Abschließende „/“ werden entfernt.
    public var normalizedURL: URL? {
        Self.normalize(backendURL)
    }

    public static func normalize(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://") {
            trimmed = (isLocalHost(trimmed) ? "http://" : "https://") + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// „192.168.1.20:8080“, „localhost“, „macbook.local:8080“, „macbook:8080“ (Name ohne
    /// Punkt, z. B. Tailscale-Kurzname) → lokales Netz.
    static func isLocalHost(_ address: String) -> Bool {
        let host = address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? address
        let name = (host.split(separator: ":").first.map(String.init) ?? host).lowercased()
        if name == "localhost" || name.hasSuffix(".local") || !name.contains(".") { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let number = Int(part), !part.isEmpty else { return false }
            return (0...255).contains(number)
        }
    }
}
