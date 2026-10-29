import Foundation
import SwiftData

/// ELRDPersistence – lokale Speicherung mit SwiftData.
///
/// Aufbau (Entscheidung E28): Statt einer Tabelle je Entität mit Beziehungen gibt es
/// flache Tabellen ohne Beziehungen. `EntityRecord` hält jede Entität als JSON plus einige
/// Spalten zum Suchen; `ChangeRecord` ist das Änderungsjournal. Kein anderes Modul
/// greift direkt auf SwiftData zu.
public enum ELRDPersistenceModule {
    public static let name = "ELRDPersistence"
}

/// Datenbankschema Version 1.
///
/// Regeln für Änderungen:
/// - Neue Felder in Domänentypen brauchen keine Schemaänderung (sie stehen im JSON),
///   müssen aber optional sein oder beim Dekodieren einen Standardwert haben.
/// - Neue oder geänderte Spalten hier erfordern `ELRDSchemaV2` und eine
///   Migrationsstufe in `ELRDMigrationPlan`.
public enum ELRDSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [EntityRecord.self, ChangeRecord.self, DocumentRecord.self]
    }

    /// Eine gespeicherte Entität (Einsatz, Patient, Einheit, …).
    ///
    /// Hinweis: `PersistentModel` belegt bereits `id` und `isDeleted`; die Spalten
    /// heißen deshalb `entityID` und `isSoftDeleted`.
    @Model
    public final class EntityRecord {
        @Attribute(.unique) public var entityID: UUID
        /// Rohwert von `SyncEntityType`.
        public var entityType: String
        public var missionID: UUID
        public var isSoftDeleted: Bool
        /// Entspricht `EntityMetadata.version`.
        public var entityVersion: Int
        public var updatedAt: Date
        /// Format des JSON-Inhalts, für spätere Umwandlungen alter Daten.
        public var payloadVersion: Int
        /// Die Entität als JSON.
        public var payload: Data

        public init(
            entityID: UUID,
            entityType: String,
            missionID: UUID,
            isSoftDeleted: Bool,
            entityVersion: Int,
            updatedAt: Date,
            payloadVersion: Int,
            payload: Data
        ) {
            self.entityID = entityID
            self.entityType = entityType
            self.missionID = missionID
            self.isSoftDeleted = isSoftDeleted
            self.entityVersion = entityVersion
            self.updatedAt = updatedAt
            self.payloadVersion = payloadVersion
            self.payload = payload
        }
    }

    /// Ein Eintrag im Änderungsjournal (`ChangeEvent`).
    @Model
    public final class ChangeRecord {
        @Attribute(.unique) public var eventID: UUID
        public var missionID: UUID
        public var entityType: String
        public var entityID: UUID
        /// HLC-Zeitstempel, aufgeteilt zum Sortieren in der Datenbank.
        public var wallTime: Int64
        public var counter: Int
        public var deviceID: UUID
        /// Noch nicht an andere Geräte bzw. das Backend übertragen (ab Schritt 53).
        public var isPendingUpload: Bool
        /// Das vollständige Ereignis als JSON.
        public var payload: Data

        public init(
            eventID: UUID,
            missionID: UUID,
            entityType: String,
            entityID: UUID,
            wallTime: Int64,
            counter: Int,
            deviceID: UUID,
            isPendingUpload: Bool,
            payload: Data
        ) {
            self.eventID = eventID
            self.missionID = missionID
            self.entityType = entityType
            self.entityID = entityID
            self.wallTime = wallTime
            self.counter = counter
            self.deviceID = deviceID
            self.isPendingUpload = isPendingUpload
            self.payload = payload
        }
    }

    /// Einzelnes Dokument unter festem Schlüssel (Stammdaten, Einstellungen).
    /// Ergänzt am 2026-10-29 vor der ersten Veröffentlichung, daher noch in V1 (E36).
    @Model
    public final class DocumentRecord {
        @Attribute(.unique) public var key: String
        public var updatedAt: Date
        public var payload: Data

        public init(key: String, updatedAt: Date, payload: Data) {
            self.key = key
            self.updatedAt = updatedAt
            self.payload = payload
        }
    }
}

/// Aktuelle Modelltypen. Code außerhalb dieses Ordners nutzt nur diese Namen.
public typealias EntityRecord = ELRDSchemaV1.EntityRecord
public typealias ChangeRecord = ELRDSchemaV1.ChangeRecord
public typealias DocumentRecord = ELRDSchemaV1.DocumentRecord

/// Migrationsplan. Neue Schemaversionen werden hier angehängt.
public enum ELRDMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [ELRDSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
