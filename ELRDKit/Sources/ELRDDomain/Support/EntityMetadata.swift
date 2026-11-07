import Foundation

/// Verwaltungsdaten, die jede gespeicherte Entität trägt.
///
/// Grundlage für den Mehrbenutzer-Modus (siehe docs/ARCHITEKTUR.md):
/// wer hat wann angelegt und zuletzt geändert, wie oft wurde geändert,
/// und ob die Entität gelöscht ist. Gelöscht wird nur weich (`deletedAt`),
/// damit eine Löschung auf andere Geräte übertragen werden kann.
///
/// Hinweis: In Schritt 7 kommen Änderungsjournal und Hybrid-Logical-Clock dazu.
/// Die Zeitstempel hier bleiben für Anzeige und Berichte erhalten.
public struct EntityMetadata: Hashable, Codable, Sendable {
    public private(set) var createdAt: Date
    public private(set) var createdBy: UserID?
    public private(set) var updatedAt: Date
    public private(set) var updatedBy: UserID?
    /// Startet bei 1 und steigt mit jeder Änderung.
    public private(set) var version: Int
    public private(set) var deletedAt: Date?

    public init(
        createdAt: Date,
        createdBy: UserID?,
        updatedAt: Date? = nil,
        updatedBy: UserID? = nil,
        version: Int = 1,
        deletedAt: Date? = nil
    ) {
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.updatedAt = updatedAt ?? createdAt
        self.updatedBy = updatedBy ?? createdBy
        self.version = max(version, 1)
        self.deletedAt = deletedAt
    }

    /// Metadaten für eine neu angelegte Entität.
    public static func new(by author: UserID?, at date: Date) -> EntityMetadata {
        EntityMetadata(createdAt: date, createdBy: author)
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// Vermerkt eine Änderung.
    public mutating func recordChange(by author: UserID?, at date: Date) {
        updatedAt = max(date, updatedAt)
        updatedBy = author
        version += 1
    }

    /// Markiert als gelöscht. Mehrfaches Löschen ändert nichts mehr.
    public mutating func markDeleted(by author: UserID?, at date: Date) {
        guard deletedAt == nil else { return }
        deletedAt = date
        recordChange(by: author, at: date)
    }

    /// Hebt eine Löschung auf (z. B. „Rückgängig“).
    public mutating func restore(by author: UserID?, at date: Date) {
        guard deletedAt != nil else { return }
        deletedAt = nil
        recordChange(by: author, at: date)
    }

    /// Gleiche Metadaten mit anderer Version (Übernahme fremder Änderungen, Schritt 53).
    public func withVersion(_ version: Int) -> EntityMetadata {
        var copy = self
        copy.version = max(version, 1)
        return copy
    }
}

/// Gemeinsame Schnittstelle aller gespeicherten Entitäten.
public protocol VersionedEntity: Identifiable, Hashable, Codable, Sendable {
    var metadata: EntityMetadata { get set }
}

public extension VersionedEntity {
    var isDeleted: Bool { metadata.isDeleted }
}

/// Entitäten, die zu genau einem Einsatz gehören. Der Einsatz ist die Einheit
/// für Freigabe und Synchronisation im Mehrbenutzer-Modus.
public protocol MissionScoped {
    var missionID: MissionID { get }
}

public extension Sequence where Element: VersionedEntity {
    /// Nur nicht gelöschte Elemente.
    var active: [Element] { filter { !$0.isDeleted } }
}
