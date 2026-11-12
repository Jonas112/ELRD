import Foundation
import ELRDDomain

/// Angaben für einen neuen Einsatz.
public struct NewMissionRequest: Sendable {
    public var reason: String
    public var type: MissionType?
    public var location: String
    public var dispatchNumber: String?
    /// Abschnitte, die sofort angelegt werden (z. B. Standardabschnitte aus den Stammdaten).
    public var sectionNames: [String]
    /// Name des Initialabschnitts (muss in `sectionNames` vorkommen).
    public var initialSectionName: String?
    /// Alarmstichwort der Erstalarmierung; legt Platzhalter-Einheiten an.
    public var alarmstichwort: Alarmstichwort?
    /// Übung (Schritt 88); mit `scenario` werden deren Patienten eingespielt.
    public var isExercise: Bool = false
    public var scenario: ExerciseScenario?
    /// Lernpfad (Schritt 139): Übung mit Anleitung.
    public var isTutorial: Bool = false
    /// Übernahme aus Alamos FE2 (Schritt 140): Ort, Tagebuch, Fahrzeuge, Patienten.
    public var alarmImport: AlarmImport?

    public init(
        reason: String = "",
        type: MissionType? = nil,
        location: String = "",
        dispatchNumber: String? = nil,
        sectionNames: [String] = [],
        initialSectionName: String? = nil,
        alarmstichwort: Alarmstichwort? = nil
    ) {
        self.reason = reason
        self.type = type
        self.location = location
        self.dispatchNumber = dispatchNumber
        self.sectionNames = sectionNames
        self.initialSectionName = initialSectionName
        self.alarmstichwort = alarmstichwort
    }

    @MainActor
    func build(into draft: inout MissionDraft, existingMissions: [Mission]) throws {
        let context = draft.context
        let mission = Mission(
            id: draft.missionID,
            metadata: context.newMetadata(),
            yearNumber: Mission.nextYearNumber(startingAt: context.now, existing: existingMissions),
            dispatchNumber: dispatchNumber,
            reason: reason,
            type: type,
            location: location,
            startedAt: context.now,
            commanderID: context.session.userID
        )
        var created = mission
        if isExercise || scenario != nil || isTutorial { created.isExercise = true }
        if isTutorial { created.isTutorial = true }
        try draft.insert(created)
        draft.log(.mission, created.isExerciseMission ? "Übung \(mission.displayNumber()) angelegt" : "Einsatz \(mission.displayNumber()) angelegt", subject: .mission(mission.id))

        for (index, name) in sectionNames.enumerated() {
            let section = MissionSection(
                missionID: draft.missionID,
                metadata: context.newMetadata(),
                name: name,
                sortIndex: index + 1,
                isInitial: name == initialSectionName
            )
            try draft.insert(section)
        }

        // Stichwort im selben Speichervorgang: Einsatz und Platzhalter entstehen zusammen.
        if let alarmstichwort {
            _ = try AddAlarmstichwort(alarmstichwort).execute(&draft)
        }
        if let scenario {
            try Self.play(scenario, into: &draft)
        }
        if let alarmImport {
            try alarmImport.apply(to: &draft)
        }
    }

    /// Übungslage einspielen: Patienten ungesichtet, Befunde in der Notiz.
    @MainActor
    static func play(_ scenario: ExerciseScenario, into draft: inout MissionDraft) throws {
        for entry in scenario.patients {
            let patient = try AddPatient(triage: .ungesichtet).execute(&draft)
            try draft.update(Patient.self, id: patient.id) {
                $0.notes = entry.findings
                $0.expectedTriage = entry.expected
                $0.estimatedAge = entry.estimatedAge
                $0.isChild = entry.isChild
            }
        }
        _ = try draft.addJournalEntry(
            text: "Übungslage „\(scenario.name)“ eingespielt: \(scenario.patients.count) Patienten, ungesichtet.",
            origin: .automatic
        )
    }
}

/// Ändert Angaben eines Patienten (Person, Nummern, Merkmale, Notiz …).
///
/// Das Protokoll nennt nur die Nummer, nie Namen (E25).
public struct EditPatient: MissionCommand {
    public let patientID: PatientID
    let transform: (inout Patient) -> Void

    public init(patientID: PatientID, _ transform: @escaping (inout Patient) -> Void) {
        self.patientID = patientID
        self.transform = transform
    }

    @discardableResult
    public func execute(_ draft: inout MissionDraft) throws -> Patient {
        guard let before = draft.get(Patient.self, id: patientID), !before.metadata.isDeleted else {
            throw CommandError.notFound(.patient)
        }
        var candidate = before
        transform(&candidate)
        guard candidate != before else { return before }
        let change = transform
        let after = try draft.update(Patient.self, id: patientID) { change(&$0) }
        if after.number != before.number {
            draft.log(.patient, "Patient \(before.number): Nummer geändert in \(after.number)", subject: .patient(patientID))
        } else {
            draft.log(.patient, "Patient \(after.number): Angaben geändert", subject: .patient(patientID))
        }
        return after
    }
}

/// Erfasst eine Verletzung. Im Protokoll ohne Diagnose (nur Nummer, E25).
public struct AddInjury: MissionCommand {
    public let patientID: PatientID
    public let injury: Injury

    public init(patientID: PatientID, injury: Injury) {
        self.patientID = patientID
        self.injury = injury
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let patient = draft.get(Patient.self, id: patientID), !patient.metadata.isDeleted else {
            throw CommandError.notFound(.patient)
        }
        guard !injury.diagnosis.isEmpty else { throw CommandError.invalid("Diagnose fehlt") }
        guard !patient.injuries.contains(where: { $0.id == injury.id }) else { return }
        let newInjury = injury
        try draft.update(Patient.self, id: patientID) { $0.addInjury(newInjury) }
        draft.log(.patient, "Patient \(patient.number): Verletzung erfasst", subject: .patient(patientID))
    }
}

/// Entfernt eine Verletzung.
public struct RemoveInjury: MissionCommand {
    public let patientID: PatientID
    public let injuryID: InjuryID

    public init(patientID: PatientID, injuryID: InjuryID) {
        self.patientID = patientID
        self.injuryID = injuryID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let patient = draft.get(Patient.self, id: patientID), !patient.metadata.isDeleted else {
            throw CommandError.notFound(.patient)
        }
        guard patient.injuries.contains(where: { $0.id == injuryID }) else { return }
        let removedID = injuryID
        try draft.update(Patient.self, id: patientID) { $0.removeInjury(removedID) }
        draft.log(.patient, "Patient \(patient.number): Verletzung entfernt", subject: .patient(patientID))
    }
}

// MARK: - Transport

/// Liest einen aktiven Patienten oder meldet „nicht gefunden“.
@MainActor
private func activePatient(_ id: PatientID, in draft: MissionDraft) throws -> Patient {
    guard let patient = draft.get(Patient.self, id: id), !patient.metadata.isDeleted else {
        throw CommandError.notFound(.patient)
    }
    return patient
}

/// Ordnet eine Einheit zu (mehrere je Patient möglich, wie ELRDRG).
public struct AssignUnit: MissionCommand {
    public let patientID: PatientID
    public let unitID: UnitID

    public init(patientID: PatientID, unitID: UnitID) {
        self.patientID = patientID
        self.unitID = unitID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let patient = try activePatient(patientID, in: draft)
        guard let unit = draft.get(MissionUnit.self, id: unitID), !unit.metadata.isDeleted else {
            throw CommandError.notFound(.unit)
        }
        guard patient.status != .released else { throw CommandError.invalid("Der Patient ist entlassen.") }
        guard !patient.unitIDs.contains(unitID) else { return }
        let assigned = unitID
        try draft.update(Patient.self, id: patientID) { $0.assign(unit: assigned) }
        draft.log(.patient, "Patient \(patient.number): \(unit.displayName) zugeordnet", subject: .patient(patientID))
    }
}

/// Löst die Zuordnung einer Einheit.
public struct UnassignUnit: MissionCommand {
    public let patientID: PatientID
    public let unitID: UnitID

    public init(patientID: PatientID, unitID: UnitID) {
        self.patientID = patientID
        self.unitID = unitID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let patient = try activePatient(patientID, in: draft)
        guard patient.unitIDs.contains(unitID) else { return }
        let name = draft.get(MissionUnit.self, id: unitID)?.displayName ?? "Einheit"
        let removed = unitID
        try draft.update(Patient.self, id: patientID) { $0.unassign(unit: removed) }
        draft.log(.patient, "Patient \(patient.number): \(name) nicht mehr zugeordnet", subject: .patient(patientID))
    }
}

/// Setzt oder entfernt die Zielklinik. Beim Wechsel beginnt die Anmeldung von vorn.
public struct SetDestination: MissionCommand {
    public let patientID: PatientID
    public let hospital: HospitalSnapshot?

    public init(patientID: PatientID, hospital: HospitalSnapshot?) {
        self.patientID = patientID
        self.hospital = hospital
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let patient = try activePatient(patientID, in: draft)
        guard patient.destination != hospital else { return }
        let target = hospital
        try draft.update(Patient.self, id: patientID) { $0.setDestination(target) }
        let text = target.map { "Zielklinik \($0.name)" } ?? "Zielklinik entfernt"
        draft.log(.patient, "Patient \(patient.number): \(text)", subject: .patient(patientID))
    }
}

/// Ändert den Anmeldestatus bei der Zielklinik.
public struct SetRegistration: MissionCommand {
    public let patientID: PatientID
    public let state: HospitalRegistrationState

    public init(patientID: PatientID, state: HospitalRegistrationState) {
        self.patientID = patientID
        self.state = state
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let patient = try activePatient(patientID, in: draft)
        guard patient.registrationState != state else { return }
        let newState = state
        try draft.update(Patient.self, id: patientID) { $0.registrationState = newState }
        draft.log(.patient, "Patient \(patient.number): Klinik \(state.displayName)", subject: .patient(patientID))
    }
}

/// Beginnt den Transport (Zeitstempel = jetzt). Braucht eine zugeordnete Einheit.
public struct StartTransport: MissionCommand {
    public let patientID: PatientID

    public init(patientID: PatientID) {
        self.patientID = patientID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let patient = try activePatient(patientID, in: draft)
        guard patient.outcome == nil else { return }
        guard !patient.unitIDs.isEmpty else { throw CommandError.invalid("Zuerst eine Einheit zuordnen.") }
        let assigned = patient.unitIDs.compactMap { draft.get(MissionUnit.self, id: $0) }
        guard assigned.contains(where: { $0.type.transportsPatients }) else {
            throw CommandError.invalid("Zum Transport ein Transportmittel (RTW, KTW, RTH) zuordnen.")
        }
        let now = draft.context.now
        try draft.update(Patient.self, id: patientID) { $0.startTransport(at: now) }
        let units = patient.unitIDs.compactMap { draft.get(MissionUnit.self, id: $0)?.displayName }.joined(separator: ", ")
        let target = patient.destination.map { " nach \($0.name)" } ?? ""
        draft.log(.patient, "Patient \(patient.number): Transport mit \(units)\(target)", subject: .patient(patientID))
    }
}

/// Entlässt einen Patienten vor Ort. Die Einheiten werden frei, ihre Namen bleiben
/// am Patienten vermerkt (wie ELRDRG).
public struct ReleasePatient: MissionCommand {
    public let patientID: PatientID
    public let clearDestination: Bool

    public init(patientID: PatientID, clearDestination: Bool = true) {
        self.patientID = patientID
        self.clearDestination = clearDestination
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let patient = try activePatient(patientID, in: draft)
        guard patient.outcome == nil else { return }
        let now = draft.context.now
        var names: [UnitID: String] = [:]
        for id in patient.unitIDs { names[id] = draft.get(MissionUnit.self, id: id)?.displayName }
        let clear = clearDestination
        let lookup = names
        try draft.update(Patient.self, id: patientID) { $0.release(at: now, unitNames: { lookup[$0] }, clearDestination: clear) }
        draft.log(.patient, "Patient \(patient.number): vor Ort entlassen", subject: .patient(patientID))
    }
}

/// Nimmt Transport bzw. Entlassung zurück (Fehlbedienung).
public struct ResetOutcome: MissionCommand {
    public let patientID: PatientID

    public init(patientID: PatientID) {
        self.patientID = patientID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let patient = try activePatient(patientID, in: draft)
        guard patient.outcome != nil else { return }
        try draft.update(Patient.self, id: patientID) { $0.resetOutcome() }
        draft.log(.patient, "Patient \(patient.number): Transport/Entlassung zurückgenommen", subject: .patient(patientID))
    }
}

/// Löscht einen Patienten (weich). Die Nummer bleibt vergeben, damit sie nicht
/// doppelt auftaucht – auch nach „Rückgängig“ direkt nach der Schnellanlage.
public struct DeletePatient: MissionCommand {
    public let patientID: PatientID

    public init(patientID: PatientID) {
        self.patientID = patientID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let patient = draft.get(Patient.self, id: patientID), !patient.metadata.isDeleted else {
            throw CommandError.notFound(.patient)
        }
        try draft.delete(Patient.self, id: patientID)
        draft.log(.patient, "Patient \(patient.number) gelöscht", subject: .patient(patientID))
    }
}

/// Löscht einen Einsatz (weich: er verschwindet aus der Liste, bleibt aber für
/// Synchronisation und Wiederherstellung erhalten). Auch für beendete Einsätze.
public struct DeleteMission: MissionCommand {
    public static var allowedOnClosedMission: Bool { true }
    public init() {}

    public func execute(_ draft: inout MissionDraft) throws {
        let missionID = draft.missionID
        let number = draft.mission.displayNumber()
        try draft.delete(Mission.self, id: missionID)
        draft.log(.mission, "Einsatz \(number) gelöscht", subject: .mission(missionID))
    }
}

/// Ändert Einsatzdaten (Grund, Art, Ort, Zeiten, km-Stand, Einsatzleiter …).
public struct EditMission: MissionCommand {
    let transform: (inout Mission) -> Void

    public init(_ transform: @escaping (inout Mission) -> Void) {
        self.transform = transform
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let before = draft.mission
        var candidate = before
        transform(&candidate)
        let issues = candidate.validate()
        guard issues.isEmpty else {
            throw CommandError.invalid(issues.map(\.description).joined(separator: " "))
        }
        let after = try draft.updateMission(transform)
        if after != before {
            draft.log(.mission, "Einsatzdaten geändert", subject: .mission(after.id))
        }
    }
}

/// Setzt den Einsatzort auf der Karte (`nil`: entfernt ihn).
public struct SetMissionCoordinate: MissionCommand {
    public let coordinate: GeoCoordinate?

    public init(_ coordinate: GeoCoordinate?) {
        self.coordinate = coordinate
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let before = draft.mission.coordinate
        guard before != coordinate else { return }
        let target = coordinate
        try draft.updateMission { $0.coordinate = target }
        let missionID = draft.missionID
        let text = target == nil ? "Einsatzort auf der Karte entfernt"
            : before == nil ? "Einsatzort auf der Karte gesetzt" : "Einsatzort auf der Karte verschoben"
        draft.log(.mission, text, subject: .mission(missionID))
    }
}

/// Beendet den Einsatz und vermerkt das im Tagebuch (wie ELRDRG).
public struct CloseMission: MissionCommand {
    public init() {}

    public func execute(_ draft: inout MissionDraft) throws {
        guard !draft.mission.isClosed else { throw CommandError.missionAlreadyClosed }
        let now = draft.context.now
        let name = draft.context.session.displayName
        try draft.updateMission { $0.close(at: now) }
        try draft.addJournalEntry(
            text: "Einsatz / Lage wurde durch \(name) beendet.",
            origin: .automatic
        )
        let missionID = draft.missionID
        draft.log(.mission, "Einsatz beendet", subject: .mission(missionID))
    }
}

/// Öffnet einen beendeten Einsatz wieder.
public struct ReopenMission: MissionCommand {
    public static var allowedOnClosedMission: Bool { true }
    public init() {}

    public func execute(_ draft: inout MissionDraft) throws {
        guard draft.mission.isClosed else { throw CommandError.missionNotClosed }
        let name = draft.context.session.displayName
        try draft.updateMission { $0.reopen() }
        try draft.addJournalEntry(
            text: "Einsatz / Lage wurde von \(name) erneut geöffnet.",
            origin: .automatic
        )
        let missionID = draft.missionID
        draft.log(.mission, "Einsatz wieder geöffnet", subject: .mission(missionID))
    }
}

/// Legt einen Patienten mit der nächsten Nummer dieses Geräts an (Schnellanlage).
public struct AddPatient: MissionCommand {
    public let triage: Sichtungskategorie
    public let sectionID: SectionID?
    /// Nummer der Patientenanhängekarte (Schritt 72).
    public let tagNumber: String?

    public init(triage: Sichtungskategorie = .defaultForNewPatient, sectionID: SectionID? = nil, tagNumber: String? = nil) {
        self.triage = triage
        self.sectionID = sectionID
        self.tagNumber = tagNumber.flatMap(Patient.normalizedTag)
    }

    public func execute(_ draft: inout MissionDraft) throws -> Patient {
        if let tagNumber, let existing = draft.all(Patient.self).first(where: { !$0.isDeleted && $0.tagNumber == tagNumber }) {
            throw CommandError.invalid("Karte \(tagNumber) gehört schon zu Patient \(existing.number).")
        }
        let number = Patient.nextNumber(prefix: draft.context.numberPrefix, existing: draft.all(Patient.self))
        // Schritt 89: ohne Angabe in den eigenen Abschnitt (geteilter Einsatz).
        let section = sectionID ?? draft.mission.ownSection(of: draft.context.session.userID)
        var patient = Patient(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            number: number,
            triage: triage,
            sectionID: section
        )
        patient.tagNumber = tagNumber
        patient.triageHistory = [TriageChange(at: draft.context.now, triage: triage)]
        try draft.insert(patient)
        draft.log(.patient, "Patient \(number) angelegt – \(triage.displayName)", subject: .patient(patient.id))
        return patient
    }
}

/// Ändert die Sichtungskategorie eines Patienten.
public struct SetTriage: MissionCommand {
    public let patientID: PatientID
    public let triage: Sichtungskategorie

    public init(patientID: PatientID, triage: Sichtungskategorie) {
        self.patientID = patientID
        self.triage = triage
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let before = draft.get(Patient.self, id: patientID), !before.isDeleted else {
            throw CommandError.notFound(.patient)
        }
        guard before.triage != triage else { return }
        let target = triage
        let now = draft.context.now
        try draft.update(Patient.self, id: patientID) { $0.recordTriage(target, at: now) }
        draft.log(
            .patient,
            "Patient \(before.number): \(before.triage.displayName) → \(triage.displayName)",
            subject: .patient(patientID)
        )
    }
}

/// Nachsichtung ohne Änderung der Kategorie (Schritt 95).
public struct ConfirmTriage: MissionCommand {
    public let patientID: PatientID

    public init(patientID: PatientID) {
        self.patientID = patientID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let patient = draft.get(Patient.self, id: patientID), !patient.isDeleted else {
            throw CommandError.notFound(.patient)
        }
        guard patient.triage.isTriaged else { throw CommandError.invalid("Patient ist noch nicht gesichtet.") }
        let now = draft.context.now
        try draft.update(Patient.self, id: patientID) { $0.confirmTriage(at: now) }
        draft.log(.patient, "Patient \(patient.number): Nachsichtung, bleibt \(patient.triage.displayName)", subject: .patient(patientID))
    }
}

/// Übernimmt den Vorschlag der geführten Sichtung (Schritt 87): SK setzen und die
/// Antworten ins Protokoll schreiben (nur Nummer, keine Namen).
public struct ApplyTriageSuggestion: MissionCommand {
    public let patientID: PatientID
    public let suggestion: TriageSuggestion

    public init(patientID: PatientID, suggestion: TriageSuggestion) {
        self.patientID = patientID
        self.suggestion = suggestion
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let before = draft.get(Patient.self, id: patientID) else { throw CommandError.notFound(.patient) }
        if before.triage == suggestion.triage, before.triage.isTriaged {
            // Gleiche Kategorie: zählt als Nachsichtung.
            let now = draft.context.now
            try draft.update(Patient.self, id: patientID) { $0.confirmTriage(at: now) }
        } else {
            try SetTriage(patientID: patientID, triage: suggestion.triage).execute(&draft)
        }
        guard let patient = draft.get(Patient.self, id: patientID) else { return }
        draft.log(.patient, "Patient \(patient.number): \(suggestion.protocolText)", subject: .patient(patientID))
    }
}

/// Fügt die Platzhalter-Einheiten eines Alarmstichworts hinzu
/// (ohne Abschnittsangabe in den Initialabschnitt).
public struct AddAlarmstichwort: MissionCommand {
    public let stichwort: Alarmstichwort
    public let sectionID: SectionID?

    public init(_ stichwort: Alarmstichwort, sectionID: SectionID? = nil) {
        self.stichwort = stichwort
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws -> [MissionUnit] {
        let section = try unitTargetSection(sectionID, in: draft)
        let units = MissionUnit.placeholders(
            for: stichwort,
            missionID: draft.missionID,
            sectionID: section?.id,
            existing: draft.all(MissionUnit.self),
            author: draft.context.session.userID,
            at: draft.context.now
        )
        for unit in units { try draft.insert(unit) }
        draft.log(.unit, "Alarmstichwort \(stichwort.rawValue) hinzugefügt: \(stichwort.summary)\(AddMasterUnits.placeText(section))")
        return units
    }
}

/// Texteintrag im Einsatztagebuch.
public struct AddJournalText: MissionCommand {
    public let text: String
    public let occurredAt: Date?

    public init(_ text: String, occurredAt: Date? = nil) {
        self.text = text
        self.occurredAt = occurredAt
    }

    public func execute(_ draft: inout MissionDraft) throws -> JournalEntry {
        let entry = try draft.addJournalEntry(text: text, origin: .manual, occurredAt: occurredAt)
        draft.log(.journal, "Tagebucheintrag \(entry.number) erfasst", subject: .journalEntry(entry.id))
        return entry
    }
}

// MARK: - Datenschutz (Schritt 102)

/// Entfernt personenbezogene Patientendaten eines beendeten Einsatzes: Namen,
/// Geburtsdatum (Alter bleibt als Schätzung), Erkennungsmerkmale, Freitext.
/// Sichtung, Verletzungen, Verbleib und Zeiten bleiben für Bericht und Statistik.
public struct AnonymizeMission: MissionCommand {
    public static var allowedOnClosedMission: Bool { true }
    /// Hinweis fürs Protokoll, z. B. „automatisch nach 90 Tagen“.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard draft.mission.isClosed else { throw CommandError.invalid("Nur beendete Einsätze lassen sich anonymisieren.") }
        guard draft.mission.anonymizedAt == nil else { return }
        let startedAt = draft.mission.startedAt
        for patient in draft.active(Patient.self) {
            try draft.update(Patient.self, id: patient.id) { patient in
                if patient.estimatedAge == nil { patient.estimatedAge = patient.age(at: startedAt) }
                patient.firstName = ""
                patient.lastName = ""
                patient.birthDate = nil
                patient.identifyingFeatures = nil
                patient.notes = ""
            }
        }
        let now = draft.context.now
        try draft.updateMission { $0.anonymizedAt = now }
        draft.log(.mission, "Personenbezogene Patientendaten entfernt (\(reason))", subject: .mission(draft.missionID))
    }
}

// MARK: - Nachbesprechung (Schritt 107)

/// Speichert die Nachbesprechung – auch bei beendetem Einsatz (sie findet meist danach statt).
public struct SetDebrief: MissionCommand {
    public static var allowedOnClosedMission: Bool { true }
    public let debrief: MissionDebrief

    public init(_ debrief: MissionDebrief) {
        self.debrief = debrief
    }

    public func execute(_ draft: inout MissionDraft) throws {
        var value = debrief
        if value.conductedAt == nil, !value.isEmpty { value.conductedAt = draft.context.now }
        let stored: MissionDebrief? = value.isEmpty && value.conductedAt == nil ? nil : value
        guard draft.mission.debrief != stored else { return }
        try draft.updateMission { $0.debrief = stored }
        draft.log(.mission, stored == nil ? "Nachbesprechung geleert" : "Nachbesprechung gespeichert", subject: .mission(draft.missionID))
    }
}
