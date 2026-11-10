import Foundation

// MARK: - Polygon und Pfeil (Schritt 115)

/// Linienzug eines Kartenobjekts: Fläche (Polygon) oder Pfeil. Steht als eigenes,
/// optionales Feld am Objekt; die Form (`MapShape`) ist dabei das umgebende
/// Rechteck – ältere App-Versionen zeigen so wenigstens die richtige Stelle (E116).
public struct MapPath: Hashable, Codable, Sendable {
    public enum Kind: String, Sendable {
        case polygon
        case arrow
    }

    public var kindRaw: String
    public var points: [GeoCoordinate]

    public init(kind: Kind, points: [GeoCoordinate]) {
        kindRaw = kind.rawValue
        self.points = points
    }

    /// Unbekannte Art (neuere App) → als Pfeil zeichnen (offener Linienzug).
    public var kind: Kind { Kind(rawValue: kindRaw) ?? .arrow }

    /// Mindestens drei Punkte für eine Fläche, zwei für einen Pfeil.
    public var minimumPoints: Int { kind == .polygon ? 3 : 2 }
    public var isValid: Bool { points.count >= minimumPoints && points.count <= 200 }

    /// Umgebendes Rechteck (mit kleinem Mindestmaß, damit es nie leer ist).
    public var bounds: GeoBounds? {
        guard let first = points.first else { return nil }
        var north = first.latitude, south = first.latitude, east = first.longitude, west = first.longitude
        for point in points.dropFirst() {
            north = max(north, point.latitude)
            south = min(south, point.latitude)
            east = max(east, point.longitude)
            west = min(west, point.longitude)
        }
        let pad = 0.00002
        if north - south < pad * 2 { north += pad; south -= pad }
        if east - west < pad * 2 { east += pad; west -= pad }
        return GeoBounds(north: north, south: south, east: east, west: west)
    }

    /// Ersatzform für ältere Apps und Listen.
    public var fallbackShape: MapShape? { bounds.map { .rectangle(bounds: $0) } }

    /// Alle Punkte um denselben Versatz verschoben, sodass der Mittelpunkt des
    /// umgebenden Rechtecks auf `newCenter` liegt.
    public func moved(to newCenter: GeoCoordinate) -> MapPath {
        guard let center = bounds?.center else { return self }
        let dLat = newCenter.latitude - center.latitude
        let dLon = newCenter.longitude - center.longitude
        let moved = points.compactMap { GeoCoordinate(latitude: $0.latitude + dLat, longitude: $0.longitude + dLon) }
        guard moved.count == points.count else { return self }
        return MapPath(kind: kind, points: moved)
    }

    /// Länge des Linienzugs in Metern (Pfeil) bzw. Umfang (Polygon).
    public var lengthMeters: Double {
        guard points.count >= 2 else { return 0 }
        var total = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        if kind == .polygon, let first = points.first, let last = points.last { total += last.distance(to: first) }
        return total
    }

    public var summary: String {
        switch kind {
        case .polygon: "Fläche, \(points.count) Ecken"
        case .arrow: "Pfeil, \(MapShape.metersText(lengthMeters))"
        }
    }
}
