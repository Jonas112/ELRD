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
        try draft.insert(mission)
        draft.log(.mission, "Einsatz \(mission.displayNumber()) angelegt", subject: .mission(mission.id))

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
        let transform = transform
        let after = try draft.update(Patient.self, id: patientID) { transform(&$0) }
        if after.number != before.number {
            draft.log(.patient, "Patient \(before.number): Nummer geändert in \(after.number)", subject: .patient(patientID))
        } else {
            draft.log(.patient, "Patient \(after.number): Angaben geändert", subject: .patient(patientID))
        }
        return after
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

    public init(triage: Sichtungskategorie = .defaultForNewPatient, sectionID: SectionID? = nil) {
        self.triage = triage
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws -> Patient {
        let number = Patient.nextNumber(prefix: draft.context.numberPrefix, existing: draft.all(Patient.self))
        let patient = Patient(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            number: number,
            triage: triage,
            sectionID: sectionID
        )
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
        try draft.update(Patient.self, id: patientID) { $0.triage = target }
        draft.log(
            .patient,
            "Patient \(before.number): \(before.triage.displayName) → \(triage.displayName)",
            subject: .patient(patientID)
        )
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
        let targetSection = sectionID ?? MissionSection.initialSection(in: draft.all(MissionSection.self))?.id
        let units = MissionUnit.placeholders(
            for: stichwort,
            missionID: draft.missionID,
            sectionID: targetSection,
            existing: draft.all(MissionUnit.self),
            author: draft.context.session.userID,
            at: draft.context.now
        )
        for unit in units { try draft.insert(unit) }
        draft.log(.unit, "Alarmstichwort \(stichwort.rawValue) hinzugefügt: \(stichwort.summary)")
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
