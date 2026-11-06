import Foundation
import ELRDDomain

// MARK: - Abschnitte

/// Liest einen aktiven Abschnitt oder meldet „nicht gefunden“.
@MainActor
private func activeSection(_ id: SectionID, in draft: MissionDraft) throws -> MissionSection {
    guard let section = draft.get(MissionSection.self, id: id), !section.metadata.isDeleted else {
        throw CommandError.notFound(.section)
    }
    return section
}

/// Legt einen Abschnitt an (frei oder aus einer Stammdaten-Vorlage).
///
/// Ohne Angabe wird der neue Abschnitt Initialabschnitt, wenn es im Einsatz
/// noch keinen gibt – sonst landen neue Einheiten nirgends (E68).
public struct AddSection: MissionCommand {
    public let name: String
    public let masterSectionID: MasterSectionID?
    /// `true`: wird Initialabschnitt (ersetzt einen vorhandenen), `false`: nie, `nil`: automatisch.
    public let makeInitial: Bool?

    public init(name: String, masterSectionID: MasterSectionID? = nil, makeInitial: Bool? = nil) {
        self.name = name
        self.masterSectionID = masterSectionID
        self.makeInitial = makeInitial
    }

    public func execute(_ draft: inout MissionDraft) throws -> MissionSection {
        let existing = draft.all(MissionSection.self)
        let becomesInitial = makeInitial ?? (MissionSection.initialSection(in: existing) == nil)
        let section = MissionSection(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            name: name,
            sortIndex: MissionSection.nextSortIndex(existing: existing),
            isInitial: false,
            masterSectionID: masterSectionID
        )
        try draft.insert(section)
        draft.log(.section, "Abschnitt „\(section.name)“ angelegt", subject: .section(section.id))
        if becomesInitial { try SetInitialSection(sectionID: section.id).execute(&draft) }
        return draft.get(MissionSection.self, id: section.id) ?? section
    }
}

/// Benennt einen Abschnitt um.
public struct RenameSection: MissionCommand {
    public let sectionID: SectionID
    public let name: String

    public init(sectionID: SectionID, name: String) {
        self.sectionID = sectionID
        self.name = name
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let section = try activeSection(sectionID, in: draft)
        let newName = MissionSection.normalizedName(name)
        guard newName != section.name else { return }
        try draft.update(MissionSection.self, id: sectionID) { $0.name = newName }
        draft.log(.section, "Abschnitt „\(section.name)“ umbenannt in „\(newName)“", subject: .section(sectionID))
    }
}

/// Legt den Initialabschnitt fest (`nil`: keiner). Höchstens einer je Einsatz.
public struct SetInitialSection: MissionCommand {
    public let sectionID: SectionID?

    public init(sectionID: SectionID?) {
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        if let requested = sectionID { _ = try activeSection(requested, in: draft) }
        let changed = MissionSection.applyingInitialRule(makeInitial: sectionID, in: draft.all(MissionSection.self))
        guard !changed.isEmpty else { return }
        for section in changed {
            let flag = section.isInitial
            try draft.update(MissionSection.self, id: section.id) { $0.isInitial = flag }
        }
        if let requested = sectionID, let initial = draft.get(MissionSection.self, id: requested) {
            draft.log(.section, "Initialabschnitt: „\(initial.name)“", subject: .section(requested))
        } else {
            draft.log(.section, "Kein Initialabschnitt mehr")
        }
    }
}

/// Löscht einen Abschnitt (weich). Seine Einheiten und Patienten stehen danach
/// „ohne Abschnitt“ – es geht nichts verloren (wie ELRDRG, E68).
public struct DeleteSection: MissionCommand {
    public let sectionID: SectionID

    public init(sectionID: SectionID) {
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let section = try activeSection(sectionID, in: draft)
        let units = draft.active(MissionUnit.self).filter { $0.sectionID == sectionID }
        for unit in units {
            try draft.update(MissionUnit.self, id: unit.id) { $0.sectionID = nil }
        }
        let patients = draft.active(Patient.self).filter { $0.sectionID == sectionID }
        for patient in patients {
            try draft.update(Patient.self, id: patient.id) { $0.sectionID = nil }
        }
        if section.isInitial {
            try draft.update(MissionSection.self, id: sectionID) { $0.isInitial = false }
        }
        try draft.delete(MissionSection.self, id: sectionID)
        let moved = units.count == 1 ? "1 Einheit" : "\(units.count) Einheiten"
        draft.log(.section, "Abschnitt „\(section.name)“ gelöscht, \(moved) ohne Abschnitt", subject: .section(sectionID))
    }
}

/// Verschiebt eine Einheit in einen Abschnitt (`nil`: ohne Abschnitt).
public struct MoveUnit: MissionCommand {
    public let unitID: UnitID
    public let sectionID: SectionID?

    public init(unitID: UnitID, to sectionID: SectionID?) {
        self.unitID = unitID
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let unit = draft.get(MissionUnit.self, id: unitID), !unit.metadata.isDeleted else {
            throw CommandError.notFound(.unit)
        }
        let target = try sectionID.map { try activeSection($0, in: draft) }
        guard unit.sectionID != sectionID else { return }
        let destination = sectionID
        try draft.update(MissionUnit.self, id: unitID) { $0.sectionID = destination }
        let targetText = target.map { "„\($0.name)“" } ?? "ohne Abschnitt"
        draft.log(.unit, "\(unit.displayName) → \(targetText)", subject: .unit(unitID))
    }
}

/// Legt einen Patienten ohne Einheit in einen Abschnitt (`nil`: keiner), z. B. in
/// die Patientenablage. Hat er schon eine Einheit, gilt deren Abschnitt – dann
/// wird abgelehnt (wie ELRDRG: „Fügen Sie das Fahrzeug dem Abschnitt hinzu“).
public struct MovePatient: MissionCommand {
    public let patientID: PatientID
    public let sectionID: SectionID?

    public init(patientID: PatientID, to sectionID: SectionID?) {
        self.patientID = patientID
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let patient = draft.get(Patient.self, id: patientID), !patient.metadata.isDeleted else {
            throw CommandError.notFound(.patient)
        }
        let target = try sectionID.map { try activeSection($0, in: draft) }
        let assigned = patient.unitIDs.compactMap { draft.get(MissionUnit.self, id: $0) }.filter { !$0.metadata.isDeleted }
        if let first = assigned.first {
            throw CommandError.invalid("Patient \(patient.number) ist \(first.displayName) zugeordnet. Die Einheit in den Abschnitt verschieben.")
        }
        guard patient.sectionID != sectionID else { return }
        let destination = sectionID
        try draft.update(Patient.self, id: patientID) { $0.sectionID = destination }
        let targetText = target.map { "„\($0.name)“" } ?? "ohne Abschnitt"
        draft.log(.patient, "Patient \(patient.number) → \(targetText)", subject: .patient(patientID))
    }
}

/// Setzt die Position eines Abschnitts auf der Lagekarte (`nil`: von der Karte nehmen).
public struct SetSectionCoordinate: MissionCommand {
    public let sectionID: SectionID
    public let coordinate: GeoCoordinate?

    public init(sectionID: SectionID, coordinate: GeoCoordinate?) {
        self.sectionID = sectionID
        self.coordinate = coordinate
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let section = try activeSection(sectionID, in: draft)
        guard section.coordinate != coordinate else { return }
        let target = coordinate
        try draft.update(MissionSection.self, id: sectionID) { $0.coordinate = target }
        let text = target == nil ? "von der Karte genommen"
            : section.coordinate == nil ? "auf der Karte gesetzt" : "auf der Karte verschoben"
        draft.log(.section, "Abschnitt „\(section.name)“ \(text)", subject: .section(sectionID))
    }
}
