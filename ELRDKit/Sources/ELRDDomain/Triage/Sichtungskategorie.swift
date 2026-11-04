/// Sichtungskategorie (SK) eines Patienten.
///
/// Rohwerte entsprechen ELRDRG und dem ELRD-Backend (`category` 1…6) und
/// dürfen nicht geändert werden.
public enum Sichtungskategorie: Int, CaseIterable, Codable, Sendable, Identifiable, Comparable, DisplayNamed {
    case sk1 = 1
    case sk2 = 2
    case sk3 = 3
    case unverletzt = 4
    case ungesichtet = 5
    case verstorben = 6

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .sk1: "Sichtungskategorie 1"
        case .sk2: "Sichtungskategorie 2"
        case .sk3: "Sichtungskategorie 3"
        case .unverletzt: "Unverletzt"
        case .ungesichtet: "Ungesichtet"
        case .verstorben: "Verstorben"
        }
    }

    public var shortName: String {
        switch self {
        case .sk1: "SK 1"
        case .sk2: "SK 2"
        case .sk3: "SK 3"
        case .unverletzt: "UV"
        case .ungesichtet: "?"
        case .verstorben: "†"
        }
    }

    /// Bedeutung der Kategorie in Worten (für Hilfetexte und Berichte).
    public var meaning: String {
        switch self {
        case .sk1: "Akute, vitale Bedrohung – Sofortbehandlung"
        case .sk2: "Schwer verletzt/erkrankt – dringliche Behandlung"
        case .sk3: "Leicht verletzt/erkrankt – spätere Behandlung"
        case .unverletzt: "Unverletzt / Betroffener"
        case .ungesichtet: "Noch nicht gesichtet"
        case .verstorben: "Verstorben"
        }
    }

    /// Kennfarbe. SK 1–3 nach üblicher Farbkodierung rot/gelb/grün.
    public var color: RGBColor {
        switch self {
        case .sk1: RGBColor(hex: 0xD32F2F)
        case .sk2: RGBColor(hex: 0xFFC107)
        case .sk3: RGBColor(hex: 0x2E7D32) // dunkler als ELRDRG, damit weiße Schrift gut lesbar ist
        case .unverletzt: RGBColor(hex: 0xE0E0E0)
        case .ungesichtet: RGBColor(hex: 0x90A4AE)
        case .verstorben: RGBColor(hex: 0x212121)
        }
    }

    /// Kategorie, mit der ein neu angelegter Patient startet.
    public static let defaultForNewPatient: Sichtungskategorie = .ungesichtet

    /// Kategorien, für die es eine Schnellanlage gibt (wie in ELRDRG).
    public static let quickAddCategories: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet]

    /// Sortierung wie in ELRDRG: nach Rohwert (SK 1 zuerst).
    public static func < (lhs: Sichtungskategorie, rhs: Sichtungskategorie) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
