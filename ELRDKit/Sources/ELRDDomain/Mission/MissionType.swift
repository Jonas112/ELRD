import Foundation

/// Einsatzart.
///
/// Rohwerte sind die Texte, die ELRDRG in `Mission.missionType` speichert.
/// „Keine Angabe“ wird über `Optional<MissionType>` abgebildet, nicht als eigener Fall.
public enum MissionType: String, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case brand = "Brand"
    case bma = "BMA"
    case verkehrsunfall = "VU"
    case gefahrgut = "Gefahrgut"
    case polizeiSonderlage = "Polizei Sonderlage"
    case vermisstensuche = "Vermisstensuche"
    case bergrettung = "Bergrettungseinsatz"
    case wasserrettung = "Wasserrettungseinsatz"
    case mehrfachErkrankte = "Mehrfach erkrankt"
    case sonstiges = "Sonstiges"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .brand: "Brand"
        case .bma: "Brandmeldeanlage"
        case .verkehrsunfall: "Verkehrsunfall"
        case .gefahrgut: "Gefahrgut"
        case .polizeiSonderlage: "Polizeiliche Sonderlage"
        case .vermisstensuche: "Vermisstensuche"
        case .bergrettung: "Bergrettung"
        case .wasserrettung: "Wasserrettung"
        case .mehrfachErkrankte: "Mehrere Erkrankte"
        case .sonstiges: "Sonstiges"
        }
    }

    public var shortName: String { rawValue }

    /// Liest den in ELRDRG gespeicherten Text. Leere Werte und der alte
    /// Platzhalter „Einsatzart auswählen“ ergeben `nil`.
    public init?(legacyValue: String?) {
        guard let value = legacyValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        self.init(rawValue: value)
    }
}
