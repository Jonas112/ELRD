import Foundation

// MARK: - Klinikkontingente (Schritt 71)

/// Wie viele Patienten je SK eine Klinik in diesem Einsatz aufnehmen kann
/// (Rückmeldung der Klinik oder ILS). `nil` = nicht bekannt / keine Grenze.
public struct HospitalQuota: Hashable, Codable, Sendable, Identifiable {
    /// Klinik aus den Stammdaten, sonst nur über den Namen erkannt.
    public var masterHospitalID: MasterHospitalID?
    public var hospitalName: String
    public var sk1: Int?
    public var sk2: Int?
    public var sk3: Int?

    public init(masterHospitalID: MasterHospitalID? = nil, hospitalName: String, sk1: Int? = nil, sk2: Int? = nil, sk3: Int? = nil) {
        self.masterHospitalID = masterHospitalID
        self.hospitalName = hospitalName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sk1 = sk1.map { max(0, $0) }
        self.sk2 = sk2.map { max(0, $0) }
        self.sk3 = sk3.map { max(0, $0) }
    }

    public var id: String { masterHospitalID?.rawValue.uuidString ?? HospitalQuota.key(hospitalName) }

    public func limit(for triage: Sichtungskategorie) -> Int? {
        switch triage {
        case .sk1: sk1
        case .sk2: sk2
        case .sk3: sk3
        default: nil
        }
    }

    public mutating func setLimit(_ value: Int?, for triage: Sichtungskategorie) {
        let clamped = value.map { max(0, $0) }
        switch triage {
        case .sk1: sk1 = clamped
        case .sk2: sk2 = clamped
        case .sk3: sk3 = clamped
        default: break
        }
    }

    /// Vergleichsschlüssel für Kliniknamen (Groß/klein, Leerzeichen egal).
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    public func matches(_ hospital: HospitalSnapshot) -> Bool {
        if let masterHospitalID, let other = hospital.masterHospitalID { return masterHospitalID == other }
        return HospitalQuota.key(hospitalName) == HospitalQuota.key(hospital.name)
    }
}

// MARK: - Führungsstruktur (Schritt 73)

/// Funktion in der Einsatzleitung.
public enum LeadershipRole: String, Codable, Sendable, CaseIterable, Identifiable, DisplayNamed {
    case einsatzleiter
    case lna
    case orgl
    case fuehrungsassistenz

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .einsatzleiter: "Einsatzleiter Rettungsdienst"
        case .lna: "Leitender Notarzt"
        case .orgl: "Organisatorischer Leiter"
        case .fuehrungsassistenz: "Führungsassistenz"
        }
    }

    public var shortName: String {
        switch self {
        case .einsatzleiter: "ELRD"
        case .lna: "LNA"
        case .orgl: "OrgL"
        case .fuehrungsassistenz: "FüAss"
        }
    }
}

/// Besetzte Funktion mit Erreichbarkeit.
public struct LeadershipPosition: Hashable, Codable, Sendable, Identifiable {
    public var role: LeadershipRole
    public var name: String
    public var callsign: String
    public var radioChannel: String

    public init(role: LeadershipRole, name: String = "", callsign: String = "", radioChannel: String = "") {
        self.role = role
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.callsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        self.radioChannel = radioChannel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var id: LeadershipRole { role }
    public var isEmpty: Bool { name.isEmpty && callsign.isEmpty && radioChannel.isEmpty }
}

/// Führungskraft aus den Einstellungen (Schritt 81) – in „Führung und Kräfte“
/// auswählbar, Freitext bleibt möglich.
public struct LeadershipPerson: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var callsign: String
    public var radioChannel: String
    /// Funktionen, für die die Person in Frage kommt (leer = alle).
    public var roles: [LeadershipRole]
    /// Telefon fürs Telefonbuch (Schritt 99); optional für ältere Einstellungen.
    public var phone: String?

    public init(id: UUID = UUID(), name: String, callsign: String = "", radioChannel: String = "", roles: [LeadershipRole] = [], phone: String? = nil) {
        self.id = id
        let trimmedPhone = phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phone = (trimmedPhone?.isEmpty ?? true) ? nil : trimmedPhone
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.callsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        self.radioChannel = radioChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.roles = roles
    }

    /// Passt die Person zu dieser Funktion (`nil` = Abschnittsleitung, alle passen)?
    public func fits(_ role: LeadershipRole?) -> Bool {
        guard let role, !roles.isEmpty else { return true }
        return roles.contains(role)
    }
}

public extension Mission {
    /// Besetzung einer Funktion (leer, wenn nicht eingetragen).
    func position(_ role: LeadershipRole) -> LeadershipPosition {
        leadership?.first { $0.role == role } ?? LeadershipPosition(role: role)
    }

    /// Setzt eine Funktion; leere Einträge werden entfernt.
    mutating func setPosition(_ position: LeadershipPosition) {
        var list = leadership ?? []
        list.removeAll { $0.role == position.role }
        if !position.isEmpty { list.append(position) }
        list.sort { LeadershipRole.allCases.firstIndex(of: $0.role)! < LeadershipRole.allCases.firstIndex(of: $1.role)! }
        leadership = list.isEmpty ? nil : list
    }

    /// Entfernt eine Klinik aus der Kontingentliste.
    mutating func removeQuota(id: String) {
        hospitalQuotas?.removeAll { $0.id == id }
        if hospitalQuotas?.isEmpty == true { hospitalQuotas = nil }
    }

    /// Kontingent einer Klinik, falls erfasst.
    func quota(for hospital: HospitalSnapshot) -> HospitalQuota? {
        hospitalQuotas?.first { $0.matches(hospital) }
    }

    /// Setzt das Kontingent einer Klinik (auch ohne Grenzen: Klinik steht dann in der Liste).
    mutating func setQuota(_ quota: HospitalQuota) {
        var list = hospitalQuotas ?? []
        list.removeAll { $0.id == quota.id }
        list.append(quota)
        list.sort { $0.hospitalName.localizedStandardCompare($1.hospitalName) == .orderedAscending }
        hospitalQuotas = list.isEmpty ? nil : list
    }
}

// MARK: - Patientenanhängekarte (Schritt 72)

public extension Patient {
    /// Einheitliche Form der Kartennummer (Leerzeichen weg, Großbuchstaben).
    static func normalizedTag(_ raw: String) -> String? {
        let cleaned = raw.uppercased().filter { !$0.isWhitespace }
        return cleaned.isEmpty ? nil : cleaned
    }
}
