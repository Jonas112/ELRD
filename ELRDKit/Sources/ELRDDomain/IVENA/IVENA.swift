/// Behandlungsdringlichkeit nach IVENA. Rohwerte wie ELRDRG (`Victim.ivena_behandlungsPRIO`).
public enum TreatmentPriority: Int, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case keineDringlichkeit = 0
    case sofortigeIntervention = 1
    case stationaereAufnahmeWahrscheinlich = 2
    case vermutlichAmbulant = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .keineDringlichkeit: "Keine Dringlichkeit angegeben"
        case .sofortigeIntervention: "Sofortige Intervention"
        case .stationaereAufnahmeWahrscheinlich: "Stationäre Aufnahme wahrscheinlich"
        case .vermutlichAmbulant: "Vermutlich ambulante Behandlung"
        }
    }

    public var shortName: String { String(rawValue) }
}

/// Rückmeldeindikator (RMI) aus einem IVENA-Katalog (dreistellige Nummer mit Titel).
///
/// Die Kataloge selbst (Bayern, Untermain) sind Daten und kommen mit den
/// Stammdaten bzw. den IVENA-Einstellungen (Schritte 11 und 49).
public struct RMI: Hashable, Codable, Sendable, Identifiable {
    /// Dreistellige Nummer, z. B. 361.
    public let code: Int
    public let title: String
    /// Kategorie im Katalog, z. B. „Verletzungen/Unfälle - Mehrfach“.
    public let category: String

    public var id: Int { code }

    public init(code: Int, title: String, category: String) {
        self.code = code
        self.title = title
        self.category = category
    }

    /// RMIs sind dreistellig (100…999).
    public var isValid: Bool { (100...999).contains(code) }
}

/// Patientenzuweisungscode (PZC) für IVENA: RMI (3) – Alter (2) – Dringlichkeit (1),
/// z. B. „361-45-1“.
///
/// Verhalten wie ELRDRG `Victim.getPZC()`:
/// - ohne gültigen RMI wird „000“ verwendet,
/// - Alter unter 1 Jahr bzw. unbekannt ergibt „00“, ab 100 Jahren „99“,
/// - die Dringlichkeit ist der Rohwert von `TreatmentPriority`.
public struct PatientAllocationCode: Hashable, Sendable, CustomStringConvertible {
    public let rmiCode: Int?
    public let ageInYears: Int?
    public let priority: TreatmentPriority

    public init(rmiCode: Int?, ageInYears: Int?, priority: TreatmentPriority) {
        self.rmiCode = rmiCode
        self.ageInYears = ageInYears
        self.priority = priority
    }

    /// Ob alle drei Bestandteile echte Angaben enthalten.
    public var isComplete: Bool {
        guard let rmiCode, (100...999).contains(rmiCode) else { return false }
        return ageInYears != nil && priority != .keineDringlichkeit
    }

    public var rmiPart: String {
        guard let rmiCode, (100...999).contains(rmiCode) else { return "000" }
        return String(rmiCode)
    }

    public var agePart: String {
        guard let age = ageInYears, age >= 1 else { return "00" }
        let clamped = min(age, 99)
        return clamped < 10 ? "0\(clamped)" : String(clamped)
    }

    public var priorityPart: String { String(priority.rawValue) }

    public var description: String { "\(rmiPart)-\(agePart)-\(priorityPart)" }
}
