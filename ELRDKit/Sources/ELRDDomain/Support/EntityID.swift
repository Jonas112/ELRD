import Foundation

/// Typsichere Kennung einer Entität.
///
/// Der Typparameter verhindert Verwechslungen (eine `UnitID` kann nicht als
/// `SectionID` übergeben werden). Gespeichert und übertragen wird nur die UUID –
/// in JSON als einfacher String, damit Backend und Sync keine Sonderbehandlung brauchen.
public struct EntityID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Erzeugt eine neue, zufällige Kennung.
    public init() {
        self.rawValue = UUID()
    }

    /// Liest eine Kennung aus einem UUID-String; `nil` bei ungültigem Format.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

/// Markierungstypen für `EntityID`. Sie haben keine Werte und dienen nur der Typsicherheit.
public enum IDTag {
    public enum Mission {}
    public enum Section {}
    public enum Unit {}
    public enum Patient {}
    public enum User {}
    public enum Device {}
    public enum MasterUnit {}
    public enum MasterSection {}
}

public typealias MissionID = EntityID<IDTag.Mission>
public typealias SectionID = EntityID<IDTag.Section>
public typealias UnitID = EntityID<IDTag.Unit>
public typealias PatientID = EntityID<IDTag.Patient>
public typealias UserID = EntityID<IDTag.User>
public typealias DeviceID = EntityID<IDTag.Device>
/// Einheit aus den Stammdaten (Vorlage, aus der eine Einsatzeinheit entsteht).
public typealias MasterUnitID = EntityID<IDTag.MasterUnit>
/// Abschnitt aus den Stammdaten.
public typealias MasterSectionID = EntityID<IDTag.MasterSection>
