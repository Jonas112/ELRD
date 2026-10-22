import Foundation
import ELRDDomain
import ELRDSync

/// Entitäten einer Art innerhalb eines Entwurfs, mit Merkliste der Änderungen.
///
/// Ändern ist nur über `MissionDraft` möglich; dort werden die Metadaten
/// (Version, Autor, Zeit) automatisch gesetzt.
public struct EntityCollection<Entity: SyncEntity>: Sendable {
    private var items: [UUID: Entity]
    private let baseline: [UUID: Entity]
    /// Geänderte Kennungen in Reihenfolge der ersten Änderung.
    private var touched: [UUID] = []

    init(_ entities: [Entity]) {
        let byID = Dictionary(entities.map { ($0.syncID, $0) }, uniquingKeysWith: { first, _ in first })
        items = byID
        baseline = byID
    }

    // MARK: Lesen

    public func get(_ id: UUID) -> Entity? { items[id] }

    /// Alle Entitäten einschließlich gelöschter, stabil sortiert nach Anlagezeit.
    public var all: [Entity] { StableOrder.sorted(items.values) }

    /// Nur nicht gelöschte Entitäten.
    public var active: [Entity] { all.filter { !$0.isDeleted } }

    // MARK: Ändern (nur über MissionDraft)

    mutating func insert(_ entity: Entity) throws {
        guard items[entity.syncID] == nil else { throw CommandError.duplicate(entity.syncID) }
        items[entity.syncID] = entity
        markTouched(entity.syncID)
    }

    @discardableResult
    mutating func update(
        _ id: UUID,
        context: CommandContext,
        _ transform: (inout Entity) throws -> Void
    ) throws -> Entity {
        guard let before = items[id], !before.isDeleted else { throw CommandError.notFound(Entity.syncEntityType) }
        var after = before
        try transform(&after)
        // Metadaten setzt allein der Entwurf.
        after.metadata = before.metadata
        if after != before {
            after.metadata.recordChange(by: context.session.userID, at: context.now)
            items[id] = after
            markTouched(id)
        }
        return after
    }

    mutating func delete(_ id: UUID, context: CommandContext) throws {
        guard var entity = items[id], !entity.isDeleted else { throw CommandError.notFound(Entity.syncEntityType) }
        entity.metadata.markDeleted(by: context.session.userID, at: context.now)
        items[id] = entity
        markTouched(id)
    }

    private mutating func markTouched(_ id: UUID) {
        if !touched.contains(id) { touched.append(id) }
    }

    /// Geänderte Entitäten mit ihrem Ausgangsstand (`nil` = neu angelegt).
    func changes() -> [(old: Entity?, new: Entity)] {
        touched.compactMap { id in
            guard let new = items[id] else { return nil }
            let old = baseline[id]
            return old == new ? nil : (old, new)
        }
    }
}

/// Einheitliche Reihenfolge für Entitäten im Store: nach Anlagezeit, bei
/// Gleichstand nach Kennung. Gilt für frisch geänderte und neu geladene Stände
/// gleichermaßen, damit beide vergleichbar sind.
enum StableOrder {
    static func sorted<Entity: SyncEntity>(_ entities: some Sequence<Entity>) -> [Entity] {
        entities.sorted {
            ($0.metadata.createdAt, $0.syncID.uuidString) < ($1.metadata.createdAt, $1.syncID.uuidString)
        }
    }
}
