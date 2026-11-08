import Foundation

/// Einsatzart. Die mitgelieferten Arten haben feste Kürzel (wie im alten Projekt);
/// eigene Arten aus den Einstellungen (Schritt 78) verwenden ihren Namen als Kürzel.
///
/// Gespeichert wird nur das Kürzel als Text – ältere Einsätze („VU“, „Brand“ …)
/// bleiben lesbar, und eine Art, die ein anderes Gerät nicht kennt, erscheint dort
/// einfach mit ihrem Namen.
public struct MissionType: RawRepresentable, Hashable, Codable, Sendable, Identifiable, DisplayNamed {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Eigene Einsatzart; `nil` bei leerem Namen.
    public init?(customName: String) {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Name einer mitgelieferten Art → diese Art verwenden.
        if let builtIn = MissionType.allCases.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame || $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) {
            self = builtIn
        } else {
            self.init(rawValue: name)
        }
    }

    public static let brand = MissionType(rawValue: "Brand")
    public static let bma = MissionType(rawValue: "BMA")
    public static let verkehrsunfall = MissionType(rawValue: "VU")
    public static let gefahrgut = MissionType(rawValue: "Gefahrgut")
    public static let polizeiSonderlage = MissionType(rawValue: "Polizei Sonderlage")
    public static let vermisstensuche = MissionType(rawValue: "Vermisstensuche")
    public static let bergrettung = MissionType(rawValue: "Bergrettungseinsatz")
    public static let wasserrettung = MissionType(rawValue: "Wasserrettungseinsatz")
    public static let mehrfachErkrankte = MissionType(rawValue: "Mehrfach erkrankt")
    public static let sonstiges = MissionType(rawValue: "Sonstiges")

    /// Mitgelieferte Einsatzarten.
    public static let allCases: [MissionType] = [
        .brand, .bma, .verkehrsunfall, .gefahrgut, .polizeiSonderlage,
        .vermisstensuche, .bergrettung, .wasserrettung, .mehrfachErkrankte, .sonstiges,
    ]

    public var isBuiltIn: Bool { MissionType.builtInNames[rawValue] != nil }

    public var id: String { rawValue }

    public var displayName: String {
        MissionType.builtInNames[rawValue] ?? rawValue
    }

    public var shortName: String { rawValue }

    private static let builtInNames: [String: String] = [
        "Brand": "Brand",
        "BMA": "Brandmeldeanlage",
        "VU": "Verkehrsunfall",
        "Gefahrgut": "Gefahrgut",
        "Polizei Sonderlage": "Polizeiliche Sonderlage",
        "Vermisstensuche": "Vermisstensuche",
        "Bergrettungseinsatz": "Bergrettung",
        "Wasserrettungseinsatz": "Wasserrettung",
        "Mehrfach erkrankt": "Mehrere Erkrankte",
        "Sonstiges": "Sonstiges",
    ]

    /// Wert aus dem alten Projekt (nur mitgelieferte Arten).
    public init?(legacyValue: String?) {
        guard let value = legacyValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, MissionType.builtInNames[value] != nil else { return nil }
        self.init(rawValue: value)
    }

    // Als einfacher Text speichern (wie bisher die Aufzählung).
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
