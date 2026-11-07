import Foundation
import ELRDDomain

/// Alle bekannten Ereignisse einer Entität – daraus entsteht ihr zusammengeführter
/// Stand einschließlich Metadaten (Schritt 53).
///
/// Regeln:
/// - Felder und Listenelemente: letzter Schreiber gewinnt (`MergeState`).
/// - Löschen und Wiederherstellen: das jüngste Ereignis vom Typ Anlegen, Löschen
///   oder Wiederherstellen entscheidet. Eine gleichzeitige Bearbeitung hebt eine
///   Löschung **nicht** auf – nur ausdrückliches Wiederherstellen.
/// - Angelegt am/von: aus dem Anlegen; geändert am/von: jüngstes Ereignis.
/// - Version: Anzahl der Ereignisse (auf allen Geräten gleich).
public struct EntityHistory: Sendable {
    /// Ereignisse ohne Doppelte, in HLC-Reihenfolge.
    public let events: [ChangeEvent]

    public init(_ events: [ChangeEvent]) {
        var seen = Set<ChangeEventID>()
        self.events = events
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public var entityID: UUID? { events.first?.entityID }
    public var entityType: SyncEntityType? { events.first?.entityType }

    /// Das (früheste) Anlegen. Ohne Anlegen ist der Stand unvollständig.
    public var insert: ChangeEvent? { events.first { $0.operation == .insert } }

    /// Jüngstes Ereignis, das über gelöscht/nicht gelöscht entscheidet.
    public var lifecycleEvent: ChangeEvent? {
        events.last { $0.operation == .insert || $0.operation == .delete || $0.operation == .restore }
    }

    public var isDeleted: Bool { lifecycleEvent?.operation == .delete }

    public func mergeState() -> MergeState {
        var state = MergeState()
        for event in events { state.apply(event) }
        return state
    }

    /// Metadaten des zusammengeführten Stands; `nil` ohne Anlegen.
    public func metadata() -> EntityMetadata? {
        guard let insert, let latest = events.last else { return nil }
        return EntityMetadata(
            createdAt: insert.timestamp.date,
            createdBy: insert.authorID,
            updatedAt: latest.timestamp.date,
            updatedBy: latest.authorID,
            version: events.count,
            deletedAt: isDeleted ? lifecycleEvent?.timestamp.date : nil
        )
    }

    /// Zusammengeführte Entität; `nil`, solange das Anlegen fehlt.
    public func entity<Entity: SyncEntity>(_ type: Entity.Type) throws -> Entity? {
        guard let metadata = metadata() else { return nil }
        return try mergeState().decode(type, metadata: JSONValueCoder.encode(metadata))
    }
}
