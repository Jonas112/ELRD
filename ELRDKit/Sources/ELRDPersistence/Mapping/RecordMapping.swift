import Foundation
import ELRDDomain
import ELRDSync

/// Fehler beim Speichern und Laden.
public enum PersistenceError: Error, Equatable, Sendable {
    /// Datensatz gehört zu einer anderen Entitätsart als angefordert.
    case typeMismatch(expected: String, found: String)
    /// Gespeichertes Format ist neuer als diese App-Version (z. B. nach Downgrade).
    case unsupportedPayloadVersion(Int)
    case unknownEntityType(String)
    /// Es soll ein älterer Stand über einen neueren geschrieben werden
    /// (z. B. zwei iPad-Fenster bearbeiten denselben Datensatz).
    case staleWrite(entityID: UUID, storedVersion: Int, newVersion: Int)
}

/// Gespeicherte Form einer Entität, unabhängig von SwiftData.
///
/// Wird beim Speichern einmal erzeugt und dann von beiden Repository-Arten
/// (SwiftData, Arbeitsspeicher) gleich verwendet – so prüfen auch die
/// In-Memory-Tests die echte Umwandlung nach JSON.
public struct EntitySnapshot: Hashable, Sendable {
    public let entityID: UUID
    public let entityType: SyncEntityType
    public let missionID: UUID
    public let isDeleted: Bool
    public let version: Int
    public let updatedAt: Date
    public let payloadVersion: Int
    public let payload: Data

    public init<Entity: SyncEntity>(_ entity: Entity) throws {
        entityID = entity.syncID
        entityType = Entity.syncEntityType
        missionID = entity.missionID.rawValue
        isDeleted = entity.isDeleted
        version = entity.metadata.version
        updatedAt = entity.metadata.updatedAt
        payloadVersion = RecordMapping.currentPayloadVersion
        payload = try RecordMapping.makeEncoder().encode(entity)
    }

    init(record: EntityRecord) throws {
        guard let type = SyncEntityType(rawValue: record.entityType) else {
            throw PersistenceError.unknownEntityType(record.entityType)
        }
        entityID = record.entityID
        entityType = type
        missionID = record.missionID
        isDeleted = record.isSoftDeleted
        version = record.entityVersion
        updatedAt = record.updatedAt
        payloadVersion = record.payloadVersion
        payload = record.payload
    }

    /// Liest die Entität. Prüft Art und Format.
    public func decode<Entity: SyncEntity>(_ type: Entity.Type) throws -> Entity {
        guard entityType == Entity.syncEntityType else {
            throw PersistenceError.typeMismatch(expected: Entity.syncEntityType.rawValue, found: entityType.rawValue)
        }
        guard payloadVersion <= RecordMapping.currentPayloadVersion else {
            throw PersistenceError.unsupportedPayloadVersion(payloadVersion)
        }
        return try JSONDecoder().decode(Entity.self, from: payload)
    }

    /// Prüft, ob dieser Stand einen gespeicherten Stand ersetzen darf.
    /// Gleiche Version mit gleichem Inhalt ist erlaubt (wiederholtes Speichern).
    func checkCanReplace(storedVersion: Int, storedPayload: Data) throws {
        if version > storedVersion { return }
        if version == storedVersion && payload == storedPayload { return }
        throw PersistenceError.staleWrite(entityID: entityID, storedVersion: storedVersion, newVersion: version)
    }
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

    public static func makeRecord(_ snapshot: EntitySnapshot) -> EntityRecord {
        EntityRecord(
            entityID: snapshot.entityID,
            entityType: snapshot.entityType.rawValue,
            missionID: snapshot.missionID,
            isSoftDeleted: snapshot.isDeleted,
            entityVersion: snapshot.version,
            updatedAt: snapshot.updatedAt,
            payloadVersion: snapshot.payloadVersion,
            payload: snapshot.payload
        )
    }

    /// Erstellt einen neuen Datensatz für eine Entität.
    public static func makeRecord<Entity: SyncEntity>(_ entity: Entity) throws -> EntityRecord {
        makeRecord(try EntitySnapshot(entity))
    }

    /// Überschreibt einen vorhandenen Datensatz mit einem neuen Stand.
    public static func update(_ record: EntityRecord, with snapshot: EntitySnapshot) throws {
        guard record.entityType == snapshot.entityType.rawValue else {
            throw PersistenceError.typeMismatch(expected: snapshot.entityType.rawValue, found: record.entityType)
        }
        record.payload = snapshot.payload
        record.payloadVersion = snapshot.payloadVersion
        record.isSoftDeleted = snapshot.isDeleted
        record.entityVersion = snapshot.version
        record.updatedAt = snapshot.updatedAt
        record.missionID = snapshot.missionID
    }

    public static func update<Entity: SyncEntity>(_ record: EntityRecord, with entity: Entity) throws {
        try update(record, with: EntitySnapshot(entity))
    }

    /// Liest die Entität aus einem Datensatz.
    public static func decode<Entity: SyncEntity>(_ type: Entity.Type, from record: EntityRecord) throws -> Entity {
        try EntitySnapshot(record: record).decode(type)
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

extension PersistenceError: LocalizedError {
    /// Text für Hinweise in der Oberfläche (Schritt 52).
    public var errorDescription: String? {
        switch self {
        case .typeMismatch, .unknownEntityType:
            "Gespeicherte Daten sind beschädigt oder unbekannt. Bitte die App aktualisieren."
        case .unsupportedPayloadVersion:
            "Die Daten wurden mit einer neueren App-Version gespeichert. Bitte die App aktualisieren."
        case .staleWrite:
            "Ein anderes Fenster hat gerade dasselbe geändert. Bitte noch einmal versuchen."
        }
    }
}
