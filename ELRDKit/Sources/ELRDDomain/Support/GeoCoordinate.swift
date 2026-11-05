import Foundation

/// Geografische Koordinate (WGS 84) ohne Abhängigkeit zu CoreLocation.
public struct GeoCoordinate: Hashable, Codable, Sendable {
    public let latitude: Double
    public let longitude: Double

    /// `nil`, wenn die Werte außerhalb des gültigen Bereichs liegen.
    public init?(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              latitude.isFinite, longitude.isFinite else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Luftlinie in Metern (Haversine, Erdradius 6 371 km). Genau genug, um Kliniken
    /// nach Nähe zu sortieren; keine Fahrstrecke.
    public func distance(to other: GeoCoordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
