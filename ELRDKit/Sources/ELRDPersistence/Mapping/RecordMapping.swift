import Foundation
import ELRDDomain
import ELRDSync

/// Fehler beim Umwandeln zwischen Domänentypen und gespeicherten Datensätzen.
public enum PersistenceError: Error, Equatable, Sendable {
    /// Datensatz gehört zu einer anderen Entitätsart als angefordert.
    case typeMismatch(expected: String, found: String)
    /// Gespeichertes Format ist neuer als diese App-Version (z. B. nach Downgrade).
    case unsupportedPayloadVersion(Int)
    case unknownEntityType(String)
}

/// Umwandlung Domäne ⇄ `EntityRecord` / `ChangeRecord`.
///
/// Das JSON-Format ist bewusst identisch zum Sync-Format (sortierte Schlüssel,
/// Datumswerte als Zahl), damit Speicherung und Synchronisation dieselben Daten sehen.
public enum RecordMapping {
    /// Aktuelles Format des JSON-Inhalts von `EntityRecord`.
    public static let currentPayloadVersion = 1

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: Entitäten

    /// Erstellt einen neuen Datensatz für eine Entität.
    public static func makeRecord<Entity: SyncEntity>(_ entity: Entity) throws -> EntityRecord {
        EntityRecord(
            entityID: entity.syncID,
            entityType: Entity.syncEntityType.rawValue,
            missionID: entity.missionID.rawValue,
            isSoftDeleted: entity.isDeleted,
            entityVersion: entity.metadata.version,
            updatedAt: entity.metadata.updatedAt,
            payloadVersion: currentPayloadVersion,
            payload: try makeEncoder().encode(entity)
        )
    }

    /// Überschreibt einen vorhandenen Datensatz mit dem neuen Stand der Entität.
    public static func update<Entity: SyncEntity>(_ record: EntityRecord, with entity: Entity) throws {
        guard record.entityType == Entity.syncEntityType.rawValue else {
            throw PersistenceError.typeMismatch(expected: Entity.syncEntityType.rawValue, found: record.entityType)
        }
        record.payload = try makeEncoder().encode(entity)
        record.payloadVersion = currentPayloadVersion
        record.isSoftDeleted = entity.isDeleted
        record.entityVersion = entity.metadata.version
        record.updatedAt = entity.metadata.updatedAt
        record.missionID = entity.missionID.rawValue
    }

    /// Liest die Entität aus einem Datensatz.
    public static func decode<Entity: SyncEntity>(_ type: Entity.Type, from record: EntityRecord) throws -> Entity {
        guard record.entityType == Entity.syncEntityType.rawValue else {
            throw PersistenceError.typeMismatch(expected: Entity.syncEntityType.rawValue, found: record.entityType)
        }
        guard record.payloadVersion <= currentPayloadVersion else {
            throw PersistenceError.unsupportedPayloadVersion(record.payloadVersion)
        }
        return try JSONDecoder().decode(Entity.self, from: record.payload)
    }

    // MARK: Änderungsjournal

    public static func makeRecord(_ event: ChangeEvent, isPendingUpload: Bool = true) throws -> ChangeRecord {
        ChangeRecord(
            eventID: event.id.rawValue,
            missionID: event.missionID.rawValue,
            entityType: event.entityType.rawValue,
            entityID: event.entityID,
            wallTime: event.timestamp.wallTime,
            counter: event.timestamp.counter,
            deviceID: event.timestamp.deviceID.rawValue,
            isPendingUpload: isPendingUpload,
            payload: try makeEncoder().encode(event)
        )
    }

    public static func decode(_ record: ChangeRecord) throws -> ChangeEvent {
        try JSONDecoder().decode(ChangeEvent.self, from: record.payload)
    }
}
