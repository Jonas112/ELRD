import Foundation
import ELRDDomain

// MARK: - Papierkorb (Schritt 54)

/// Ein gelöschter Eintrag, der sich wiederherstellen lässt.
public struct TrashItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case patient
        case journalEntry
        case mapObject

        public var displayName: String {
            switch self {
            case .patient: "Patient"
            case .journalEntry: "Tagebuch"
            case .mapObject: "Lagekarte"
            }
        }

        public var systemImage: String {
            switch self {
            case .patient: "person.fill"
            case .journalEntry: "book.pages"
            case .mapObject: "map"
            }
        }
    }

    public let kind: Kind
    public let entityID: UUID
    public let title: String
    public let deletedAt: Date
    public let deletedBy: UserID?

    public var id: String { "\(kind.rawValue)/\(entityID.uuidString)" }
}

public extension MissionState {
    /// Gelöschte Patienten, Tagebucheinträge und Kartenobjekte, zuletzt gelöschte zuerst.
    var trash: [TrashItem] {
        var items: [TrashItem] = []
        for patient in patients where patient.isDeleted {
            items.append(Self.item(.patient, patient.id.rawValue, "Patient \(patient.number) · \(patient.triage.shortName)", patient.metadata))
        }
        for entry in journal where entry.isDeleted && entry.origin != .automatic {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = text.isEmpty ? "Anhang" : String(text.prefix(60)) + (text.count > 60 ? " …" : "")
            items.append(Self.item(.journalEntry, entry.id.rawValue, "\(entry.number): \(preview)", entry.metadata))
        }
        for object in mapObjects where object.isDeleted {
            items.append(Self.item(.mapObject, object.id.rawValue, object.displayName, object.metadata))
        }
        return items.sorted { ($0.deletedAt, $0.id) > ($1.deletedAt, $1.id) }
    }

    private static func item(_ kind: TrashItem.Kind, _ id: UUID, _ title: String, _ metadata: EntityMetadata) -> TrashItem {
        TrashItem(kind: kind, entityID: id, title: title, deletedAt: metadata.deletedAt ?? metadata.updatedAt, deletedBy: metadata.updatedBy)
    }
}

/// Stellt einen gelöschten Patienten, Tagebucheintrag oder ein Kartenobjekt wieder her.
public struct RestoreDeleted: MissionCommand {
    public let kind: TrashItem.Kind
    public let entityID: UUID

    public init(kind: TrashItem.Kind, entityID: UUID) {
        self.kind = kind
        self.entityID = entityID
    }

    public init(_ item: TrashItem) {
        self.init(kind: item.kind, entityID: item.entityID)
    }

    public func execute(_ draft: inout MissionDraft) throws {
        switch kind {
        case .patient:
            let id = PatientID(entityID)
            try draft.restore(Patient.self, id: id)
            if let patient = draft.get(Patient.self, id: id) {
                draft.log(.patient, "Patient \(patient.number) wiederhergestellt", subject: .patient(id))
            }
        case .journalEntry:
            let id = JournalEntryID(entityID)
            try draft.restore(JournalEntry.self, id: id)
            if let entry = draft.get(JournalEntry.self, id: id) {
                draft.log(.journal, "Tagebucheintrag \(entry.number) wiederhergestellt", subject: .journalEntry(id))
            }
        case .mapObject:
            let id = MapObjectID(entityID)
            try draft.restore(MapObject.self, id: id)
            if let object = draft.get(MapObject.self, id: id) {
                draft.log(.map, "„\(object.displayName)“ auf der Karte wiederhergestellt", subject: .mapObject(id))
            }
        }
    }
}

/// Holt einen gelöschten Einsatz zurück in die Einsatzliste.
public struct RestoreMission: MissionCommand {
    public static var allowedOnClosedMission: Bool { true }
    public init() {}

    public func execute(_ draft: inout MissionDraft) throws {
        let missionID = draft.missionID
        try draft.restore(Mission.self, id: missionID)
        draft.log(.mission, "Einsatz \(draft.mission.displayNumber()) wiederhergestellt", subject: .mission(missionID))
    }
}
