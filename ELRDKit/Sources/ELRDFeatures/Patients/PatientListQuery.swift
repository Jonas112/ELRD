import Foundation
import ELRDDomain
import ELRDStore

/// Filter nach Versorgungsstand.
public enum PatientStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, waiting, assigned, inTransport, released

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Alle"
        case .waiting: "Warten"
        case .assigned: "Zugeordnet"
        case .inTransport: "Transport"
        case .released: "Entlassen"
        }
    }

    func matches(_ patient: Patient) -> Bool {
        switch self {
        case .all: true
        case .waiting: patient.status == .waiting
        case .assigned: patient.status == .assigned
        case .inTransport: patient.status == .inTransport
        case .released: patient.status == .released
        }
    }
}

public enum PatientSort: String, CaseIterable, Sendable {
    /// Offene zuerst, dann SK 1, 2, 3, ungesichtet, unverletzt, verstorben, dann Nummer.
    case triage
    /// Nach Nummer (A-1, A-2, …, B-1).
    case number

    var title: String {
        switch self {
        case .triage: "nach SK"
        case .number: "nach Nummer"
        }
    }
}

/// Auswahl der Patientenliste: Stand, Sichtungskategorie, Suche, Sortierung.
public struct PatientListQuery: Equatable, Sendable {
    public var status: PatientStatusFilter = .all
    /// Gesetzt durch Tipp auf einen SK-Zähler in der Lageleiste.
    public var triage: Sichtungskategorie?
    public var searchText = ""
    public var sort: PatientSort = .triage

    public init(status: PatientStatusFilter = .all, triage: Sichtungskategorie? = nil, searchText: String = "", sort: PatientSort = .triage) {
        self.status = status
        self.triage = triage
        self.searchText = searchText
        self.sort = sort
    }

    public var isFiltered: Bool {
        status != .all || triage != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Reihenfolge der Kategorien in Listen (wie die Zähler).
    static let triageOrder: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet, .unverletzt, .verstorben]

    public func apply(to patients: [Patient]) -> [Patient] {
        let filtered = patients.active.filter { patient in
            status.matches(patient)
                && (triage == nil || patient.triage == triage)
                && matchesSearch(patient)
        }
        switch sort {
        case .number:
            return filtered.sorted { ($0.number, $0.id.rawValue.uuidString) < ($1.number, $1.id.rawValue.uuidString) }
        case .triage:
            return filtered.sorted { Self.triageKey($0) < Self.triageKey($1) }
        }
    }

    /// Anzahl je Stand – innerhalb der gewählten SK und Suche, damit die Zahlen zum Ergebnis passen.
    public func statusCounts(in patients: [Patient]) -> [PatientStatusFilter: Int] {
        let base = patients.active.filter { (triage == nil || $0.triage == triage) && matchesSearch($0) }
        return Dictionary(uniqueKeysWithValues: PatientStatusFilter.allCases.map { filter in
            (filter, base.filter(filter.matches).count)
        })
    }

    /// Suchwörter in Nummer, ILS-Nummer, Name oder Notiz (Groß/klein und Akzente egal).
    func matchesSearch(_ patient: Patient) -> Bool {
        let words = searchText.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [
            patient.number.description,
            patient.number.description.replacingOccurrences(of: "-", with: ""),
            patient.dispatchPatientNumber ?? "",
            patient.firstName,
            patient.lastName,
            patient.notes,
        ].joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func triageKey(_ patient: Patient) -> (Int, Int, SerialNumber, String) {
        let done = patient.status == .released || patient.status == .inTransport
        let rank = triageOrder.firstIndex(of: patient.triage) ?? triageOrder.count
        return (done ? 1 : 0, rank, patient.number, patient.id.rawValue.uuidString)
    }
}

/// Aufbereitete Zeile der Patientenliste.
struct PatientRow: Identifiable, Equatable {
    let id: PatientID
    let triage: Sichtungskategorie
    let number: String
    /// Name oder `nil`, wenn unbekannt.
    let name: String?
    /// ILS-Nummer, Geschlecht/Alter, erste Diagnose.
    let details: String
    let unitText: String
    let hasUnit: Bool
    let status: PatientStatus
    let destination: String?
    let registration: HospitalRegistrationState?
    let isDuplicateNumber: Bool

    init(patient: Patient, units: [MissionUnit], duplicates: Set<SerialNumber>, now: Date) {
        id = patient.id
        triage = patient.triage
        number = patient.number.description
        name = patient.fullName.isEmpty ? nil : patient.fullName
        var parts: [String] = []
        if let ils = patient.dispatchPatientNumber, !ils.isEmpty { parts.append("ILS \(ils)") }
        var person: [String] = []
        if patient.gender != .unklar { person.append(patient.gender.shortName) }
        if let age = patient.age(at: now) { person.append(patient.birthDate == nil ? "~\(age) J" : "\(age) J") }
        if !person.isEmpty { parts.append(person.joined(separator: " ")) }
        if let injury = patient.injuries.first { parts.append(injury.diagnosis) }
        details = parts.joined(separator: " · ")

        let assigned = units.filter { patient.unitIDs.contains($0.id) }.map(\.displayName)
        hasUnit = !assigned.isEmpty
        status = patient.status
        switch patient.status {
        case .released: unitText = "entlassen"
        case .inTransport: unitText = assigned.isEmpty ? "im Transport" : "\(assigned.joined(separator: ", ")) · Transport"
        default: unitText = assigned.isEmpty ? "keine Einheit" : assigned.joined(separator: ", ")
        }
        destination = patient.destination?.name
        registration = patient.destination == nil ? nil : patient.registrationState
        isDuplicateNumber = duplicates.contains(patient.number)
    }

    static func rows(for patients: [Patient], state: MissionState, now: Date) -> [PatientRow] {
        let duplicates = Patient.duplicateNumbers(in: state.patients)
        return patients.map { PatientRow(patient: $0, units: state.units, duplicates: duplicates, now: now) }
    }
}
