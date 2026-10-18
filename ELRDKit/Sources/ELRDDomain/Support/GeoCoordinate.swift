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
}
