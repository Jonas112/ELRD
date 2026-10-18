import Foundation

/// Objekt auf der Lagekarte: Kreis (z. B. Gefahrenbereich), Rechteck oder Freihandzeichnung.
///
/// Abschnitte werden nicht hier gespeichert – sie tragen ihre Position selbst
/// (`MissionSection.coordinate`).
public struct MapObject: VersionedEntity, MissionScoped {
    public let id: MapObjectID
    public let missionID: MissionID
    public var metadata: EntityMetadata

    public var title: String
    public var note: String
    public var color: RGBColor
    public private(set) var shape: MapShape

    /// `nil`, wenn die Form ungültig ist (siehe `MapShape.isValid`).
    public init?(
        id: MapObjectID = MapObjectID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        title: String = "",
        note: String = "",
        color: RGBColor = MapObject.defaultColor,
        shape: MapShape
    ) {
        guard shape.isValid else { return nil }
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note
        self.color = color
        self.shape = shape
    }

    /// Rot wie in ELRDRG.
    public static let defaultColor = RGBColor(hex: 0xD32F2F)

    /// Ändert die Form. Gibt `false` zurück und lässt alles unverändert, wenn die Form ungültig ist.
    @discardableResult
    public mutating func setShape(_ newShape: MapShape) -> Bool {
        guard newShape.isValid else { return false }
        shape = newShape
        return true
    }

    /// Anzeigename: Titel, sonst Beschreibung der Form.
    public var displayName: String {
        title.isEmpty ? shape.summary : title
    }
}

/// Geometrie eines Kartenobjekts.
public enum MapShape: Hashable, Codable, Sendable {
    /// Kreis mit Radius in Metern.
    case circle(center: GeoCoordinate, radiusMeters: Double)
    case rectangle(bounds: GeoBounds)
    /// Freihandzeichnung als transparentes Bild, aufgespannt über `bounds`.
    case drawing(bounds: GeoBounds, image: FileAttachment)

    /// Kleinster und größter erlaubter Kreisradius in Metern.
    public static let radiusRange: ClosedRange<Double> = 1...50_000

    public var isValid: Bool {
        switch self {
        case let .circle(_, radius):
            return radius.isFinite && Self.radiusRange.contains(radius)
        case .rectangle:
            return true
        case let .drawing(_, image):
            return image.kind == .drawing
        }
    }

    /// Bezugspunkt, z. B. zum Zentrieren der Karte.
    public var center: GeoCoordinate {
        switch self {
        case let .circle(center, _): center
        case let .rectangle(bounds), let .drawing(bounds, _): bounds.center
        }
    }

    /// Kurzbeschreibung, z. B. „Kreis, Radius 250 m“.
    public var summary: String {
        switch self {
        case let .circle(_, radius): "Kreis, Radius \(Int(radius.rounded())) m"
        case .rectangle: "Rechteck"
        case .drawing: "Zeichnung"
        }
    }
}
