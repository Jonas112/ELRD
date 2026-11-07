import Foundation

/// Näherungen für kleine Flächen (Einsatzstelle, wenige Kilometer): ein Breitengrad
/// ≈ 111,32 km, ein Längengrad entsprechend kürzer. Genau genug für Markierungen.
private let metersPerDegreeLatitude = 111_320.0

private func metersPerDegreeLongitude(at latitude: Double) -> Double {
    metersPerDegreeLatitude * cos(latitude * .pi / 180)
}

public extension GeoBounds {
    /// Rechteck um einen Mittelpunkt mit Breite und Höhe in Metern.
    static func around(_ center: GeoCoordinate, widthMeters: Double, heightMeters: Double) -> GeoBounds? {
        let perLongitude = metersPerDegreeLongitude(at: center.latitude)
        guard perLongitude > 1, widthMeters.isFinite, heightMeters.isFinite, widthMeters > 0, heightMeters > 0 else { return nil }
        let halfLatitude = heightMeters / 2 / metersPerDegreeLatitude
        let halfLongitude = widthMeters / 2 / perLongitude
        return GeoBounds(
            north: center.latitude + halfLatitude,
            south: center.latitude - halfLatitude,
            east: center.longitude + halfLongitude,
            west: center.longitude - halfLongitude
        )
    }

    /// Ost-West-Ausdehnung in Metern (in der Mitte gemessen).
    var widthMeters: Double { (east - west) * metersPerDegreeLongitude(at: (north + south) / 2) }

    /// Nord-Süd-Ausdehnung in Metern.
    var heightMeters: Double { (north - south) * metersPerDegreeLatitude }
}

public extension MapShape {
    var isCircle: Bool {
        if case .circle = self { return true }
        return false
    }

    var isDrawing: Bool {
        if case .drawing = self { return true }
        return false
    }

    /// Dieselbe Form mit neuem Mittelpunkt (Größe bleibt).
    func moved(to newCenter: GeoCoordinate) -> MapShape {
        switch self {
        case let .circle(_, radius):
            return .circle(center: newCenter, radiusMeters: radius)
        case let .rectangle(bounds):
            guard let moved = GeoBounds.around(newCenter, widthMeters: bounds.widthMeters, heightMeters: bounds.heightMeters) else { return self }
            return .rectangle(bounds: moved)
        case let .drawing(bounds, image):
            guard let moved = GeoBounds.around(newCenter, widthMeters: bounds.widthMeters, heightMeters: bounds.heightMeters) else { return self }
            return .drawing(bounds: moved, image: image)
        }
    }

    /// Kleinste Größe beim Ziehen am Griff (Schritt 60).
    static let minimumSizeMeters = 5.0

    /// Stelle des Griffs zum Ändern der Größe: Kreis am Ostrand, Rechteck und
    /// Zeichnung an der Südost-Ecke.
    var resizeHandle: GeoCoordinate? {
        switch self {
        case let .circle(center, radius):
            let perLongitude = metersPerDegreeLongitude(at: center.latitude)
            guard perLongitude > 1 else { return nil }
            return GeoCoordinate(latitude: center.latitude, longitude: center.longitude + radius / perLongitude)
        case let .rectangle(bounds), let .drawing(bounds, _):
            return GeoCoordinate(latitude: bounds.south, longitude: bounds.east)
        }
    }

    /// Neue Form, nachdem der Griff an `handle` gezogen wurde. Kreis: Mittelpunkt
    /// bleibt, Radius = Abstand zum Griff. Rechteck/Zeichnung: Nordwest-Ecke bleibt.
    func resized(handle: GeoCoordinate) -> MapShape {
        switch self {
        case let .circle(center, _):
            let perLongitude = metersPerDegreeLongitude(at: center.latitude)
            let dx = (handle.longitude - center.longitude) * perLongitude
            let dy = (handle.latitude - center.latitude) * metersPerDegreeLatitude
            let radius = max((dx * dx + dy * dy).squareRoot(), Self.minimumSizeMeters)
            return .circle(center: center, radiusMeters: radius)
        case let .rectangle(bounds):
            return .rectangle(bounds: Self.resize(bounds, to: handle))
        case let .drawing(bounds, image):
            return .drawing(bounds: Self.resize(bounds, to: handle), image: image)
        }
    }

    private static func resize(_ bounds: GeoBounds, to handle: GeoCoordinate) -> GeoBounds {
        let perLongitude = metersPerDegreeLongitude(at: bounds.north)
        let minLatitude = minimumSizeMeters / metersPerDegreeLatitude
        let minLongitude = perLongitude > 1 ? minimumSizeMeters / perLongitude : minLatitude
        return GeoBounds(
            north: bounds.north,
            south: min(handle.latitude, bounds.north - minLatitude),
            east: max(handle.longitude, bounds.west + minLongitude),
            west: bounds.west
        ) ?? bounds
    }

    /// Größe als Text, z. B. „Radius 100 m“ oder „200 × 100 m“.
    var sizeText: String {
        switch self {
        case let .circle(_, radius):
            return "Radius \(Self.metersText(radius))"
        case let .rectangle(bounds), let .drawing(bounds, _):
            let width = bounds.widthMeters
            let height = bounds.heightMeters
            if width < 1000, height < 1000 {
                return "\(Int(width.rounded())) × \(Int(height.rounded())) m"
            }
            return "\(Self.metersText(width)) × \(Self.metersText(height))"
        }
    }

    /// „250 m“ bzw. ab 1 000 m „1,5 km“.
    static func metersText(_ meters: Double) -> String {
        if meters >= 1000 {
            let kilometers = (meters / 100).rounded() / 10
            let text = kilometers == kilometers.rounded() ? String(Int(kilometers)) : String(kilometers).replacingOccurrences(of: ".", with: ",")
            return "\(text) km"
        }
        return "\(Int(meters.rounded())) m"
    }
}
