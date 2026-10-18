import Foundation

/// Patient bzw. betroffene Person in einem Einsatz.
public struct Patient: VersionedEntity, MissionScoped {
    public let id: PatientID
    public let missionID: MissionID
    public var metadata: EntityMetadata

    // MARK: Kennzeichnung

    /// Patientennummer im Einsatz (Anzeige, Anhängekarte). Nicht der Schlüssel.
    /// Doppelte Nummern sind möglich (z. B. Tippfehler) und werden über
    /// `Patient.duplicateNumbers` angezeigt, nicht verhindert.
    public var number: Int
    /// Patientennummer der Leitstelle (ILS).
    public var dispatchPatientNumber: String?

    // MARK: Sichtung und Person

    public var triage: Sichtungskategorie
    public var firstName: String
    public var lastName: String
    /// Alter in Jahren, wenn kein Geburtsdatum bekannt ist (geschätzt oder erfragt).
    public var estimatedAge: Int?
    /// Hat Vorrang vor `estimatedAge`.
    public var birthDate: Date?
    public var isChild: Bool
    public var gender: Gender
    /// Freitext für Zusatzinformationen.
    public var notes: String

    // MARK: Medizinisches

    public private(set) var injuries: [Injury]
    public var traumaRoom: TraumaRoom
    public var isIntubated: Bool
    public var circulation: CirculationState
    /// IVENA-Rückmeldeindikator (dreistellig).
    public var rmiCode: Int?
    public var treatmentPriority: TreatmentPriority

    // MARK: Organisation und Transport

    /// Abschnitt, in dem sich der Patient befindet (z. B. Patientenablage).
    public var sectionID: SectionID?
    /// Zugeordnete Einheiten (versorgend/transportierend), in Zuordnungsreihenfolge, ohne Doppelte.
    public private(set) var unitIDs: [UnitID]
    public var destination: HospitalSnapshot?
    public var registrationState: HospitalRegistrationState
    public private(set) var outcome: PatientOutcome?

    public init(
        id: PatientID = PatientID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        number: Int,
        triage: Sichtungskategorie = .defaultForNewPatient,
        dispatchPatientNumber: String? = nil,
        firstName: String = "",
        lastName: String = "",
        estimatedAge: Int? = nil,
        birthDate: Date? = nil,
        isChild: Bool = false,
        gender: Gender = .unklar,
        notes: String = "",
        injuries: [Injury] = [],
        traumaRoom: TraumaRoom = .none,
        isIntubated: Bool = false,
        circulation: CirculationState = .unbekannt,
        rmiCode: Int? = nil,
        treatmentPriority: TreatmentPriority = .keineDringlichkeit,
        sectionID: SectionID? = nil,
        unitIDs: [UnitID] = [],
        destination: HospitalSnapshot? = nil,
        registrationState: HospitalRegistrationState = .unklar,
        outcome: PatientOutcome? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.number = number
        self.triage = triage
        self.dispatchPatientNumber = dispatchPatientNumber
        self.firstName = firstName
        self.lastName = lastName
        self.estimatedAge = estimatedAge
        self.birthDate = birthDate
        self.isChild = isChild
        self.gender = gender
        self.notes = notes
        self.injuries = []
        self.traumaRoom = traumaRoom
        self.isIntubated = isIntubated
        self.circulation = circulation
        self.rmiCode = rmiCode
        self.treatmentPriority = treatmentPriority
        self.sectionID = sectionID
        self.unitIDs = []
        self.destination = destination
        self.registrationState = registrationState
        self.outcome = outcome
        for injury in injuries { addInjury(injury) }
        for unitID in unitIDs { assign(unit: unitID) }
    }
}

/// Abschluss der Versorgung eines Patienten.
public enum PatientOutcome: Hashable, Codable, Sendable {
    /// Transport begonnen (in ELRDRG „Transportbeginn“).
    case transported(startedAt: Date)
    /// Vor Ort entlassen. `handledBy` hält die Namen der versorgenden Einheiten fest,
    /// weil die Zuordnung zu den Einheiten dabei gelöst wird.
    case released(at: Date, handledBy: [String])

    public var date: Date {
        switch self {
        case let .transported(date), let .released(date, _): date
        }
    }
}

/// Bearbeitungsstand eines Patienten für Listen und Filter.
public enum PatientStatus: Int, CaseIterable, Comparable, Sendable, DisplayNamed {
    /// Noch keiner Einheit zugeordnet.
    case waiting = 0
    /// Einheit zugeordnet, Transport noch nicht begonnen.
    case assigned = 1
    case inTransport = 2
    case released = 3

    public var displayName: String {
        switch self {
        case .waiting: "Wartet auf Einheit"
        case .assigned: "Einheit zugeordnet"
        case .inTransport: "Im Transport"
        case .released: "Entlassen"
        }
    }

    public static func < (lhs: PatientStatus, rhs: PatientStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Person

public extension Patient {
    /// „Nachname, Vorname“; leer, wenn beides fehlt.
    var fullName: String {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (last.isEmpty, first.isEmpty) {
        case (true, true): return ""
        case (false, true): return last
        case (true, false): return first
        case (false, false): return "\(last), \(first)"
        }
    }

    /// Anzeigename für Listen, z. B. „P 12 – Muster, Max“ oder „P 12“.
    var displayName: String {
        fullName.isEmpty ? "P \(number)" : "P \(number) – \(fullName)"
    }

    /// Alter in vollen Jahren am Stichtag: aus dem Geburtsdatum, sonst die Schätzung.
    func age(at date: Date, calendar: Calendar = .current) -> Int? {
        if let birthDate {
            guard birthDate <= date else { return nil }
            return calendar.dateComponents([.year], from: birthDate, to: date).year
        }
        return estimatedAge
    }

    /// Setzt ein Alter. Ein vorhandenes Geburtsdatum wird wie in ELRDRG verschoben
    /// (gleicher Tag und Monat, Jahr = Stichtagsjahr − Alter); sonst wird geschätzt.
    mutating func setAge(_ age: Int?, at date: Date, calendar: Calendar = .current) {
        guard let age, (0...Patient.maximumAge).contains(age) else {
            estimatedAge = nil
            return
        }
        if let birthDate {
            var components = calendar.dateComponents([.day, .month, .year], from: birthDate)
            components.year = calendar.component(.year, from: date) - age
            self.birthDate = calendar.date(from: components) ?? birthDate
            estimatedAge = nil
        } else {
            estimatedAge = age
        }
    }

    static let maximumAge = 130
    static let childAgeLimit = 18
}

// MARK: - Verletzungen

public extension Patient {
    /// Fügt eine Verletzung hinzu. Leere Diagnosen und doppelte Kennungen werden ignoriert.
    mutating func addInjury(_ injury: Injury) {
        guard !injury.diagnosis.isEmpty, !injuries.contains(where: { $0.id == injury.id }) else { return }
        injuries.append(injury)
    }

    mutating func updateInjury(_ injury: Injury) {
        guard let index = injuries.firstIndex(where: { $0.id == injury.id }), !injury.diagnosis.isEmpty else { return }
        injuries[index] = injury
    }

    mutating func removeInjury(_ id: InjuryID) {
        injuries.removeAll { $0.id == id }
    }

    /// Alle medizinischen Angaben als Textzeilen, wie ELRDRG `allInjurieInformation`
    /// (Verletzungen, dann Schockraum, Intubation, Kreislauf).
    var medicalSummaryLines: [String] {
        var lines = injuries.map(\.displayText)
        if traumaRoom != .none { lines.append(traumaRoom.displayName) }
        if isIntubated { lines.append("Intubiert / beatmet") }
        if circulation != .unbekannt { lines.append(circulation.displayName) }
        return lines
    }
}

// MARK: - IVENA

public extension Patient {
    func allocationCode(at date: Date, calendar: Calendar = .current) -> PatientAllocationCode {
        PatientAllocationCode(rmiCode: rmiCode, ageInYears: age(at: date, calendar: calendar), priority: treatmentPriority)
    }
}

// MARK: - Einheiten, Transport, Entlassung

public extension Patient {
    var status: PatientStatus {
        switch outcome {
        case .released: .released
        case .transported: .inTransport
        case nil: unitIDs.isEmpty ? .waiting : .assigned
        }
    }

    /// Ordnet eine Einheit zu (keine Doppelten). Ohne Wirkung bei entlassenen Patienten.
    mutating func assign(unit unitID: UnitID) {
        guard status != .released, !unitIDs.contains(unitID) else { return }
        unitIDs.append(unitID)
    }

    mutating func unassign(unit unitID: UnitID) {
        unitIDs.removeAll { $0 == unitID }
    }

    /// Beginnt den Transport. Ohne Wirkung, wenn bereits transportiert oder entlassen.
    mutating func startTransport(at date: Date) {
        guard outcome == nil else { return }
        outcome = .transported(startedAt: date)
    }

    /// Entlässt den Patienten vor Ort. Die Namen der zugeordneten Einheiten werden
    /// festgehalten und die Zuordnung gelöst (wie ELRDRG „Entlassen“).
    /// `unitNames` liefert die Anzeigenamen zu den Kennungen.
    mutating func release(at date: Date, unitNames: (UnitID) -> String?, clearDestination: Bool) {
        guard outcome == nil else { return }
        let names = unitIDs.compactMap(unitNames)
        unitIDs.removeAll()
        if clearDestination {
            destination = nil
            registrationState = .unklar
        }
        outcome = .released(at: date, handledBy: names)
    }

    /// Setzt Transport bzw. Entlassung zurück. Gelöste Einheitenzuordnungen
    /// werden dabei nicht wiederhergestellt.
    mutating func resetOutcome() {
        outcome = nil
    }

    /// Setzt eine Zielklinik. Beim Wechsel der Klinik beginnt die Anmeldung von vorn.
    mutating func setDestination(_ hospital: HospitalSnapshot?) {
        if hospital?.masterHospitalID != destination?.masterHospitalID || hospital?.name != destination?.name {
            registrationState = .unklar
        }
        destination = hospital
    }
}

// MARK: - Sammlungen

public extension Patient {
    /// Nächste Patientennummer: höchste vorhandene + 1 (wie ELRDRG).
    /// Mehrbenutzerfähige Vergabe folgt in Schritt 7.
    static func nextNumber(existing patients: some Sequence<Patient>) -> Int {
        (patients.active.map(\.number).max() ?? 0) + 1
    }

    /// Patientennummern, die mehrfach vergeben sind (nur aktive Patienten).
    static func duplicateNumbers(in patients: some Sequence<Patient>) -> Set<Int> {
        var seen = Set<Int>()
        var duplicates = Set<Int>()
        for number in patients.active.map(\.number) where !seen.insert(number).inserted {
            duplicates.insert(number)
        }
        return duplicates
    }

    /// Anzahl je Sichtungskategorie (nur aktive Patienten); fehlende Kategorien mit 0.
    static func countsByTriage(_ patients: some Sequence<Patient>) -> [Sichtungskategorie: Int] {
        var counts = Dictionary(uniqueKeysWithValues: Sichtungskategorie.allCases.map { ($0, 0) })
        for patient in patients.active { counts[patient.triage, default: 0] += 1 }
        return counts
    }

    /// Sortierung wie ELRDRG: nach Sichtungskategorie, dann Nummer.
    static func sortedByTriage(_ patients: some Sequence<Patient>) -> [Patient] {
        patients.active.sorted { ($0.triage.rawValue, $0.number) < ($1.triage.rawValue, $1.number) }
    }

    static func sortedByNumber(_ patients: some Sequence<Patient>) -> [Patient] {
        patients.active.sorted { ($0.number, $0.triage.rawValue) < ($1.number, $1.triage.rawValue) }
    }
}

public extension MissionUnit {
    /// Patienten, denen diese Einheit zugeordnet ist.
    func patients(in patients: some Sequence<Patient>) -> [Patient] {
        patients.active.filter { $0.unitIDs.contains(id) }
    }

    /// Frei = keinem aktiven Patienten zugeordnet.
    func isFree(in patients: some Sequence<Patient>) -> Bool {
        !patients.active.contains { $0.unitIDs.contains(id) }
    }
}
