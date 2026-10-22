import Foundation
import ELRDDomain
import ELRDSync

/// Zusammengehörige Änderungen, die gemeinsam gespeichert werden – ganz oder gar nicht.
///
/// Beispiel: Ein Alarmstichwort legt drei Einheiten an und erzeugt drei
/// Journaleinträge. Schlägt das Speichern fehl, bleibt der alte Stand vollständig erhalten.
public struct ChangeSet: Sendable {
    public private(set) var snapshots: [EntitySnapshot] = []
    public private(set) var events: [ChangeEvent] = []

    public init() {}

    /// Merkt eine Entität zum Speichern vor (neu oder geändert).
    /// Eine spätere Vormerkung derselben Entität ersetzt die frühere.
    public mutating func upsert<Entity: SyncEntity>(_ entity: Entity) throws {
        let snapshot = try EntitySnapshot(entity)
        snapshots.removeAll { $0.entityID == snapshot.entityID }
        snapshots.append(snapshot)
    }

    public mutating func record(_ event: ChangeEvent) {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
    }

    public var isEmpty: Bool { snapshots.isEmpty && events.isEmpty }
}

/// Lese- und Schreibzugriff auf alle einsatzbezogenen Daten.
///
/// Nur die Command-Schicht (`MissionStore`, Schritt 10) schreibt über dieses
/// Protokoll; Oberflächen lesen ausschließlich über den Store.
/// Läuft auf dem Main Actor, weil SwiftData-Kontexte nicht threadsicher sind.
@MainActor
public protocol EntityRepository: AnyObject {
    /// Speichert alle Änderungen atomar.
    /// - Throws: `PersistenceError.staleWrite`, wenn ein älterer Stand einen neueren
    ///   überschreiben würde; dann wird nichts gespeichert.
    func apply(_ changeSet: ChangeSet) throws

    /// Eine Entität nach Kennung (auch gelöschte).
    func entity<Entity: SyncEntity>(_ type: Entity.Type, id: UUID) throws -> Entity?

    /// Alle Entitäten einer Art in einem Einsatz.
    func entities<Entity: SyncEntity>(_ type: Entity.Type, in missionID: MissionID, includeDeleted: Bool) throws -> [Entity]

    /// Alle Einsätze, neueste zuerst.
    func missions(includeDeleted: Bool) throws -> [Mission]

    /// Änderungsjournal eines Einsatzes in HLC-Reihenfolge.
    func changeEvents(in missionID: MissionID) throws -> [ChangeEvent]

    /// Jüngster Zeitstempel dieses Geräts – damit die HLC nach einem Neustart
    /// nie hinter bereits vergebene Zeitstempel zurückfällt.
    func latestTimestamp(of deviceID: DeviceID) throws -> HybridTimestamp?

    /// Löscht einen Einsatz mit allen Daten und Journaleinträgen endgültig (DSGVO).
    /// Dateien (Fotos, Audio) entfernt der Aufrufer separat.
    func purgeMission(_ missionID: MissionID) throws
}

public extension EntityRepository {
    func entities<Entity: SyncEntity>(_ type: Entity.Type, in missionID: MissionID) throws -> [Entity] {
        try entities(type, in: missionID, includeDeleted: false)
    }

    func missions() throws -> [Mission] {
        try missions(includeDeleted: false)
    }

    func entity<Entity: SyncEntity, Tag>(_ type: Entity.Type, id: EntityID<Tag>) throws -> Entity? {
        try entity(type, id: id.rawValue)
    }
}

/// Gemeinsame Sortierung beider Repository-Arten.
enum RepositoryOrdering {
    static func newestFirst(_ missions: [Mission]) -> [Mission] {
        missions.sorted { ($0.startedAt, $0.yearNumber) > ($1.startedAt, $1.yearNumber) }
    }

    static func chronological(_ events: [ChangeEvent]) -> [ChangeEvent] {
        events.sorted { $0.timestamp < $1.timestamp }
    }
}
