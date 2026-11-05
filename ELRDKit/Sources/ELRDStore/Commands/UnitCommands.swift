import Foundation
import ELRDDomain

// MARK: - Einheiten

/// Zielabschnitt: angegeben (muss aktiv sein) oder der Initialabschnitt.
@MainActor
private func targetSection(_ requested: SectionID?, in draft: MissionDraft) throws -> MissionSection? {
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
        let section = try targetSection(sectionID, in: draft)
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
        let section = try targetSection(sectionID, in: draft)
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
