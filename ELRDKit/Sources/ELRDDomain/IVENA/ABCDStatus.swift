import Foundation

/// Buchstabe des ABCD-Schemas für IVENA bei Behandlungspriorität 1 (E50).
///
/// Zusatzinformation für die Klinik; ohne Einfluss auf den PZC.
public enum ABCDLetter: String, CaseIterable, Codable, Sendable, Identifiable {
    case airway = "A"
    case breathing = "B"
    case circulation = "C"
    case disability = "D"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .airway: "Atemweg"
        case .breathing: "Atmung"
        case .circulation: "Kreislauf"
        case .disability: "Bewusstsein"
        }
    }

    /// Bedeutung der Stufen 1–4, ausführlich (Auswahlmenü, Bericht).
    public var levels: [String] {
        switch self {
        case .airway: ["frei", "gefährdet", "gesichert (z. B. SGA, ITN, Koniotomie)", "kritisch / ungesichert"]
        case .breathing: ["unbeeinträchtigt", "beeinträchtigt", "NIV-beatmet", "invasiv beatmet"]
        case .circulation: ["stabil", "stabil nach Kreislauftherapie", "stabil unter kontinuierlicher Katecholamintherapie", "instabil unter Therapie"]
        case .disability: ["wach", "Bewusstsein getrübt", "bewusstlos", "sediert / narkotisiert"]
        }
    }

    /// Kurzform für Knöpfe.
    public var shortLevels: [String] {
        switch self {
        case .airway: ["frei", "gefährdet", "gesichert", "kritisch"]
        case .breathing: ["unbeeinträchtigt", "beeinträchtigt", "NIV", "invasiv beatmet"]
        case .circulation: ["stabil", "nach Therapie", "Katecholamine", "instabil"]
        case .disability: ["wach", "getrübt", "bewusstlos", "sediert"]
        }
    }

    public static let levelRange = 1...4

    /// Kürzel wie „C3“.
    public func code(_ level: Int) -> String { "\(rawValue)\(level)" }
}

/// ABCD-Status eines Patienten; jede Angabe 1–4 oder leer.
public struct ABCDStatus: Hashable, Codable, Sendable {
    public var airway: Int?
    public var breathing: Int?
    public var circulation: Int?
    public var disability: Int?

    public init(airway: Int? = nil, breathing: Int? = nil, circulation: Int? = nil, disability: Int? = nil) {
        self.airway = Self.valid(airway)
        self.breathing = Self.valid(breathing)
        self.circulation = Self.valid(circulation)
        self.disability = Self.valid(disability)
    }

    public subscript(letter: ABCDLetter) -> Int? {
        get {
            switch letter {
            case .airway: airway
            case .breathing: breathing
            case .circulation: circulation
            case .disability: disability
            }
        }
        set {
            let value = Self.valid(newValue)
            switch letter {
            case .airway: airway = value
            case .breathing: breathing = value
            case .circulation: circulation = value
            case .disability: disability = value
            }
        }
    }

    public var isEmpty: Bool { ABCDLetter.allCases.allSatisfy { self[$0] == nil } }

    /// Kurzschreibweise, z. B. „A2 B2 C2 D–“.
    public var summary: String {
        ABCDLetter.allCases.map { letter in self[letter].map { letter.code($0) } ?? "\(letter.rawValue)–" }.joined(separator: " ")
    }

    private static func valid(_ value: Int?) -> Int? {
        guard let value, ABCDLetter.levelRange.contains(value) else { return nil }
        return value
    }
}
