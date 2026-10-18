import Foundation
import ELRDDomain

/// Ein Eintrag im Änderungsjournal: Was hat wer auf welchem Gerät wann geändert.
///
/// Das Journal ist nur anfügbar (append-only). Es ist die Grundlage für
/// Protokollansicht und – im Mehrbenutzer-Modus – für die Synchronisation.
/// Ereignisse enthalten nur geänderte Felder, nicht die ganze Entität.
public struct ChangeEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: ChangeEventID
    /// Einsatz, zu dem die Änderung gehört (Einheit für Freigabe und Sync).
    public let missionID: MissionID
    public let entityType: SyncEntityType
    public let entityID: UUID
    public let operation: ChangeOperation
    public let changes: [FieldChange]
    public let timestamp: HybridTimestamp
    public let authorID: UserID?

    public init(
        id: ChangeEventID = ChangeEventID(),
        missionID: MissionID,
        entityType: SyncEntityType,
        entityID: UUID,
        operation: ChangeOperation,
        changes: [FieldChange],
        timestamp: HybridTimestamp,
        authorID: UserID?
    ) {
        self.id = id
        self.missionID = missionID
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.changes = changes
        self.timestamp = timestamp
        self.authorID = authorID
    }

    public var deviceID: DeviceID { timestamp.deviceID }
}

public typealias ChangeEventID = EntityID<ChangeEventTag>
public enum ChangeEventTag {}

/// Art der Änderung.
public enum ChangeOperation: String, Codable, Sendable, CaseIterable {
    case insert
    case update
    /// Weiches Löschen (`deletedAt` gesetzt).
    case delete
    /// Löschung aufgehoben.
    case restore
}

/// Synchronisierbare Entitätsarten. Rohwerte sind Teil des Sync-Formats und
/// dürfen nicht geändert werden.
public enum SyncEntityType: String, Codable, Sendable, CaseIterable {
    case mission
    case section
    case unit
    case patient
    case journalEntry
    case message
    case logEntry
    case mapObject
}

/// Änderung eines einzelnen Felds bzw. eines Listenelements.
///
/// Listen mit Kennungen (z. B. Verletzungen, zugeordnete Einheiten) werden
/// elementweise beschrieben. So gehen gleichzeitige Ergänzungen auf zwei
/// Geräten nicht verloren.
public enum FieldChange: Hashable, Codable, Sendable {
    /// Feld erhält einen neuen Wert.
    case set(field: String, value: JSONValue)
    /// Listenelement hinzufügen oder ersetzen.
    case upsertElement(field: String, elementID: String, value: JSONValue)
    /// Listenelement entfernen.
    case removeElement(field: String, elementID: String)

    public var field: String {
        switch self {
        case let .set(field, _), let .upsertElement(field, _, _), let .removeElement(field, _): field
        }
    }

    /// Schlüssel, unter dem der Zeitstempel für die Konfliktauflösung geführt wird.
    public var conflictKey: String {
        switch self {
        case let .set(field, _): field
        case let .upsertElement(field, elementID, _), let .removeElement(field, elementID): "\(field)[\(elementID)]"
        }
    }
}

/// Entitäten, die im Änderungsjournal erfasst werden.
public protocol SyncEntity: VersionedEntity, MissionScoped {
    static var syncEntityType: SyncEntityType { get }
    var syncID: UUID { get }
}

extension Mission: SyncEntity {
    public static var syncEntityType: SyncEntityType { .mission }
    public var syncID: UUID { id.rawValue }
}

extension MissionSection: SyncEntity {
    public static var syncEntityType: SyncEntityType { .section }
    public var syncID: UUID { id.rawValue }
}

extension MissionUnit: SyncEntity {
    public static var syncEntityType: SyncEntityType { .unit }
    public var syncID: UUID { id.rawValue }
}

extension Patient: SyncEntity {
    public static var syncEntityType: SyncEntityType { .patient }
    public var syncID: UUID { id.rawValue }
}

extension JournalEntry: SyncEntity {
    public static var syncEntityType: SyncEntityType { .journalEntry }
    public var syncID: UUID { id.rawValue }
}

extension MissionMessage: SyncEntity {
    public static var syncEntityType: SyncEntityType { .message }
    public var syncID: UUID { id.rawValue }
}

extension MissionLogEntry: SyncEntity {
    public static var syncEntityType: SyncEntityType { .logEntry }
    public var syncID: UUID { id.rawValue }
}

extension MapObject: SyncEntity {
    public static var syncEntityType: SyncEntityType { .mapObject }
    public var syncID: UUID { id.rawValue }
}
