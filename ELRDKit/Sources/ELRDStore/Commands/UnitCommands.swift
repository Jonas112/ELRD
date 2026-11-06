import Foundation
import ELRDDomain

// MARK: - Einheiten

/// Zielabschnitt: angegeben (muss aktiv sein) oder der Initialabschnitt.
@MainActor
func unitTargetSection(_ requested: SectionID?, in draft: MissionDraft) throws -> MissionSection? {
    if let requested {
        guard let section = draft.get(MissionSection.self, id: requested), !section.metadata.isDeleted else {
            throw CommandError.notFound(.section)
        }
        return section
    }
    return MissionSection.initialSection(in: draft.all(MissionSection.self))
}

/// Fügt Einheiten aus den Stammdaten hinzu. Bereits eingesetzte werden
/// übersprungen (ELRDRG: nur „unbenutzte“ Einheiten wählbar).
public struct AddMasterUnits: MissionCommand {
    public let units: [MasterUnit]
    /// `nil`: Initialabschnitt.
    public let sectionID: SectionID?

    public init(_ units: [MasterUnit], sectionID: SectionID? = nil) {
        self.units = units
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws -> [MissionUnit] {
        let section = try unitTargetSection(sectionID, in: draft)
        var used = Set(draft.active(MissionUnit.self).compactMap(\.masterUnitID))
        var added: [MissionUnit] = []
        for master in units {
            guard used.insert(master.id).inserted else { continue }
            let unit = MissionUnit.from(master, missionID: draft.missionID, metadata: draft.context.newMetadata(), sectionID: section?.id)
            try draft.insert(unit)
            added.append(unit)
            draft.log(.unit, "\(unit.displayName) hinzugefügt\(Self.placeText(section))", subject: .unit(unit.id))
        }
        return added
    }

    static func placeText(_ section: MissionSection?) -> String {
        section.map { " → „\($0.name)“" } ?? ""
    }
}

/// Legt eine Einheit an, die nicht in den Stammdaten steht (ELRDRG: temporäre Einheit).
/// Ein Funkrufname, der im Einsatz schon vorkommt, wird abgelehnt.
public struct AddTemporaryUnit: MissionCommand {
    public let callsign: String
    public let type: UnitType
    public let sectionID: SectionID?

    public init(callsign: String, type: UnitType, sectionID: SectionID? = nil) {
        self.callsign = callsign
        self.type = type
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws -> MissionUnit {
        let section = try unitTargetSection(sectionID, in: draft)
        let unit = MissionUnit(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            type: type,
            callsign: callsign,
            sectionID: section?.id
        )
        guard let key = unit.matchKey else { throw CommandError.invalid("Bitte einen Funkrufnamen eingeben.") }
        if draft.active(MissionUnit.self).contains(where: { $0.matchKey == key }) {
            throw CommandError.invalid("„\(unit.displayName)“ ist schon im Einsatz.")
        }
        try draft.insert(unit)
        draft.log(.unit, "\(unit.displayName) (temporär) hinzugefügt\(AddMasterUnits.placeText(section))", subject: .unit(unit.id))
        return unit
    }
}

/// Entfernt eine Einheit aus dem Einsatz (weich). Solange sie Patienten zugeordnet
/// ist, die nicht entlassen sind, wird das abgelehnt – sonst ginge der Transport verloren.
public struct RemoveUnit: MissionCommand {
    public let unitID: UnitID

    public init(unitID: UnitID) {
        self.unitID = unitID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let unit = draft.get(MissionUnit.self, id: unitID), !unit.metadata.isDeleted else {
            throw CommandError.notFound(.unit)
        }
        let open = Patient.sortedByNumber(draft.active(Patient.self).filter { $0.status != .released && $0.unitIDs.contains(unit.id) })
        guard open.isEmpty else {
            let numbers = open.map(\.number.description).joined(separator: ", ")
            throw CommandError.invalid("\(unit.displayName) ist noch Patient \(numbers) zugeordnet. Zuerst die Zuordnung lösen.")
        }
        try draft.delete(MissionUnit.self, id: unitID)
        draft.log(.unit, "\(unit.displayName) aus dem Einsatz entfernt", subject: .unit(unitID))
    }
}

// MARK: - Platzhalter

/// Legt einen Platzhalter an (Schnellanlage RTW/KTW/NEF, wie in ELRDRG):
/// Ein Fahrzeug ist alarmiert, aber noch nicht bekannt, welches.
public struct AddPlaceholder: MissionCommand {
    public let type: UnitType
    /// `nil`: Initialabschnitt.
    public let sectionID: SectionID?

    public init(type: UnitType, sectionID: SectionID? = nil) {
        self.type = type
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws -> MissionUnit {
        let section = try unitTargetSection(sectionID, in: draft)
        let unit = MissionUnit(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            placeholderType: type,
            number: MissionUnit.nextPlaceholderNumber(existing: draft.all(MissionUnit.self)),
            sectionID: section?.id
        )
        try draft.insert(unit)
        draft.log(.unit, "\(unit.displayName) angelegt\(AddMasterUnits.placeText(section))", subject: .unit(unit.id))
        return unit
    }
}

/// Ersetzt einen Platzhalter durch das tatsächliche Fahrzeug – aus den Stammdaten
/// oder mit eingegebenem Funkrufnamen. Kennung, Abschnitt und Patienten bleiben.
public struct ReplacePlaceholder: MissionCommand {
    public enum Replacement: Sendable {
        case master(MasterUnit)
        case temporary(callsign: String, type: UnitType)
    }

    public let unitID: UnitID
    public let replacement: Replacement

    public init(unitID: UnitID, with replacement: Replacement) {
        self.unitID = unitID
        self.replacement = replacement
    }

    public func execute(_ draft: inout MissionDraft) throws -> MissionUnit {
        guard let before = draft.get(MissionUnit.self, id: unitID), !before.metadata.isDeleted else {
            throw CommandError.notFound(.unit)
        }
        guard before.isPlaceholder else {
            throw CommandError.invalid("\(before.displayName) ist kein Platzhalter mehr.")
        }
        let others = draft.active(MissionUnit.self).filter { $0.id != unitID }
        let newCallsign: String
        let newType: UnitType
        let newLabel: String?
        let newCrew: Int?
        let newMaster: MasterUnitID?
        switch replacement {
        case .master(let master):
            if others.contains(where: { $0.masterUnitID == master.id }) {
                throw CommandError.invalid("„\(master.callsign)“ ist schon im Einsatz.")
            }
            newCallsign = master.callsign
            newType = master.type
            newLabel = master.typeLabel
            newCrew = master.crewCount
            newMaster = master.id
        case .temporary(let enteredCallsign, let enteredType):
            newCallsign = enteredCallsign.trimmingCharacters(in: .whitespacesAndNewlines)
            newType = enteredType
            newLabel = nil
            newCrew = nil
            newMaster = nil
        }
        guard !newCallsign.isEmpty else { throw CommandError.invalid("Bitte einen Funkrufnamen eingeben.") }
        let key = MasterDataMatching.key(newCallsign)
        if others.contains(where: { $0.matchKey == key }) {
            throw CommandError.invalid("„\(newCallsign)“ ist schon im Einsatz.")
        }
        try draft.update(MissionUnit.self, id: unitID) {
            _ = $0.replacePlaceholder(
                callsign: newCallsign,
                type: newType,
                typeLabel: newLabel,
                crewCount: newCrew,
                masterUnitID: newMaster
            )
        }
        let after = draft.get(MissionUnit.self, id: unitID) ?? before
        draft.log(.unit, "\(before.displayName) ist \(after.displayName)", subject: .unit(unitID))
        return after
    }
}
