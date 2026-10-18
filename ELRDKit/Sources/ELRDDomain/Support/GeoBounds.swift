/// Rechteckiger Kartenausschnitt in geografischen Koordinaten (WGS 84).
///
/// Ersetzt die MapKit-spezifischen `MKMapRect`-Werte aus ELRDRG, damit die Domäne
/// plattformunabhängig bleibt. Ausschnitte über die Datumsgrenze werden nicht
/// unterstützt (für Einsätze in Deutschland ohne Bedeutung).
public struct GeoBounds: Hashable, Codable, Sendable {
    public let north: Double
    public let south: Double
    public let east: Double
    public let west: Double

    /// `nil`, wenn die Werte ungültig sind oder Süden nördlich von Norden liegt.
    public init?(north: Double, south: Double, east: Double, west: Double) {
        guard GeoCoordinate(latitude: north, longitude: east) != nil,
              GeoCoordinate(latitude: south, longitude: west) != nil,
              south <= north, west <= east else { return nil }
        self.north = north
        self.south = south
        self.east = east
        self.west = west
    }

    /// Kleinster Ausschnitt, der beide Punkte enthält.
    public init(enclosing first: GeoCoordinate, _ second: GeoCoordinate) {
        north = max(first.latitude, second.latitude)
        south = min(first.latitude, second.latitude)
        east = max(first.longitude, second.longitude)
        west = min(first.longitude, second.longitude)
    }

    public var center: GeoCoordinate {
        // Werte stammen aus gültigen Koordinaten, der Mittelpunkt ist daher immer gültig.
        GeoCoordinate(latitude: (north + south) / 2, longitude: (east + west) / 2)!
    }

    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        (south...north).contains(coordinate.latitude) && (west...east).contains(coordinate.longitude)
    }
}
