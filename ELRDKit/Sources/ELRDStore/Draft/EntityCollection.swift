import Foundation
import ELRDDomain
import ELRDSync

/// Entitäten einer Art innerhalb eines Entwurfs, mit Merkliste der Änderungen.
///
/// Ändern ist nur über `MissionDraft` möglich; dort werden die Metadaten
/// (Version, Autor, Zeit) automatisch gesetzt.
///
/// Leistung (Schritt 64): Die Entitäten liegen bereits sortiert vor (`ordered`).
/// Lesen sortiert nicht mehr bei jedem Zugriff, Ändern ersetzt an Ort und Stelle,
/// Neues wird hinten angehängt (es ist fast immer das jüngste). Bei großen
/// Einsätzen (hunderte Patienten, tausende Protokolleinträge) bleibt jeder Befehl
/// so unabhängig von der Größe schnell.
public struct EntityCollection<Entity: SyncEntity>: Sendable {
    /// Alle Entitäten in `StableOrder`.
    private var ordered: [Entity]
    /// Position in `ordered` je Kennung.
    private var position: [UUID: Int]
    /// Ausgangsstand der geänderten Entitäten (`nil` = neu angelegt), in Reihenfolge der ersten Änderung.
    private var touched: [UUID] = []
    private var original: [UUID: Entity?] = [:]

    init(_ entities: [Entity]) {
        // Stände aus `MissionState` sind schon sortiert; nur sonst sortieren.
        let sorted = StableOrder.isSorted(entities) ? entities : StableOrder.sorted(entities)
        var unique: [Entity] = []
        var position: [UUID: Int] = [:]
        unique.reserveCapacity(sorted.count)
        position.reserveCapacity(sorted.count)
        for entity in sorted where position[entity.syncID] == nil {
            position[entity.syncID] = unique.count
            unique.append(entity)
        }
        ordered = unique
        self.position = position
    }

    // MARK: Lesen

    public func get(_ id: UUID) -> Entity? {
        position[id].map { ordered[$0] }
    }

    /// Alle Entitäten einschließlich gelöschter, stabil sortiert nach Anlagezeit.
    public var all: [Entity] { ordered }

    /// Nur nicht gelöschte Entitäten.
    public var active: [Entity] { ordered.filter { !$0.isDeleted } }

    // MARK: Ändern (nur über MissionDraft)

    mutating func insert(_ entity: Entity) throws {
        guard position[entity.syncID] == nil else { throw CommandError.duplicate(entity.syncID) }
        remember(entity.syncID, old: nil)
        if let last = ordered.last, StableOrder.precedes(entity, last) {
            // Selten (Uhr zurückgestellt, Import): an der richtigen Stelle einsortieren.
            ordered.append(entity)
            ordered = StableOrder.sorted(ordered)
            reindex()
        } else {
            position[entity.syncID] = ordered.count
            ordered.append(entity)
        }
    }

    @discardableResult
    mutating func update(
        _ id: UUID,
        context: CommandContext,
        _ transform: (inout Entity) throws -> Void
    ) throws -> Entity {
        guard let index = position[id], !ordered[index].isDeleted else { throw CommandError.notFound(Entity.syncEntityType) }
        let before = ordered[index]
        var after = before
        try transform(&after)
        // Metadaten setzt allein der Entwurf.
        after.metadata = before.metadata
        if after != before {
            after.metadata.recordChange(by: context.session.userID, at: context.now)
            remember(id, old: before)
            ordered[index] = after
        }
        return after
    }

    mutating func delete(_ id: UUID, context: CommandContext) throws {
        guard let index = position[id], !ordered[index].isDeleted else { throw CommandError.notFound(Entity.syncEntityType) }
        remember(id, old: ordered[index])
        ordered[index].metadata.markDeleted(by: context.session.userID, at: context.now)
    }

    /// Hebt eine Löschung auf (Papierkorb, Schritt 54).
    mutating func restore(_ id: UUID, context: CommandContext) throws {
        guard let index = position[id], ordered[index].isDeleted else { throw CommandError.notFound(Entity.syncEntityType) }
        remember(id, old: ordered[index])
        ordered[index].metadata.restore(by: context.session.userID, at: context.now)
    }

    /// Merkt den Ausgangsstand beim ersten Ändern.
    private mutating func remember(_ id: UUID, old: Entity?) {
        guard original[id] == nil else { return }
        original[id] = .some(old)
        touched.append(id)
    }

    private mutating func reindex() {
        position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.syncID, $0.offset) })
    }

    /// Geänderte Entitäten mit ihrem Ausgangsstand (`nil` = neu angelegt).
    func changes() -> [(old: Entity?, new: Entity)] {
        touched.compactMap { id in
            guard let new = get(id) else { return nil }
            let old = original[id] ?? nil
            return old == new ? nil : (old, new)
        }
    }
}

/// Einheitliche Reihenfolge für Entitäten im Store: nach Anlagezeit, bei
/// Gleichstand nach Kennung. Gilt für frisch geänderte und neu geladene Stände
/// gleichermaßen, damit beide vergleichbar sind.
enum StableOrder {
    static func sorted<Entity: SyncEntity>(_ entities: some Sequence<Entity>) -> [Entity] {
        entities.sorted(by: precedes)
    }

    static func isSorted<Entity: SyncEntity>(_ entities: [Entity]) -> Bool {
        guard entities.count > 1 else { return true }
        for index in 1..<entities.count where precedes(entities[index], entities[index - 1]) {
            return false
        }
        return true
    }

    /// Anlagezeit, bei Gleichstand Kennung. Die Kennung wird byteweise verglichen –
    /// gleiche Reihenfolge wie `uuidString`, aber ohne Texte zu erzeugen (Schritt 64).
    static func precedes<Entity: SyncEntity>(_ lhs: Entity, _ rhs: Entity) -> Bool {
        let left = lhs.metadata.createdAt
        let right = rhs.metadata.createdAt
        if left != right { return left < right }
        return uuidPrecedes(lhs.syncID, rhs.syncID)
    }

    static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        withUnsafeBytes(of: lhs.uuid) { left in
            withUnsafeBytes(of: rhs.uuid) { right in
                for index in 0..<16 where left[index] != right[index] {
                    return left[index] < right[index]
                }
                return false
            }
        }
    }
}
