import Foundation
import MapKit
import UIKit
import ELRDDomain
import ELRDStore

/// Abschnitt für Karte und Liste daneben.
struct MapSectionPin: Identifiable, Equatable {
    let id: SectionID
    let name: String
    /// „2 RTW · 1 NEF“ (leer ohne Einheiten).
    let summary: String
    let isInitial: Bool
    /// `nil`: noch nicht auf der Karte.
    let coordinate: GeoCoordinate?

    /// Alle aktiven Abschnitte in Anzeige-Reihenfolge, mit Einheitenübersicht.
    static func pins(for state: MissionState) -> [MapSectionPin] {
        SectionColumn.columns(for: state).compactMap { column in
            guard let section = column.section else { return nil }
            return MapSectionPin(
                id: section.id,
                name: section.name,
                summary: column.typeSummary,
                isInitial: section.isInitial,
                coordinate: section.coordinate
            )
        }
    }
}

/// Markierung eines Abschnitts auf der Karte (verschiebbar).
final class SectionAnnotation: NSObject, MKAnnotation {
    let sectionID: SectionID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(pin: MapSectionPin, coordinate: CLLocationCoordinate2D) {
        sectionID = pin.id
        self.coordinate = coordinate
        title = pin.name
        subtitle = pin.summary.isEmpty ? nil : pin.summary
        super.init()
    }
}

/// Zugriff auf die Karte von SwiftUI aus, z. B. um einen Ablagepunkt in eine
/// Koordinate umzurechnen.
@MainActor
final class MapCanvasProxy {
    weak var map: MKMapView?

    /// Norden oben und ohne Neigung – sonst passt eine Freihandzeichnung nicht auf ihr Rechteck.
    func resetHeading() {
        guard let map, map.camera.heading != 0 || map.camera.pitch != 0 else { return }
        let camera = MKMapCamera(
            lookingAtCenter: map.camera.centerCoordinate,
            fromDistance: map.camera.centerCoordinateDistance,
            pitch: 0,
            heading: 0
        )
        map.setCamera(camera, animated: false)
    }

    /// Bildschirmpunkt eines Orts (Kartenansicht).
    func point(for coordinate: GeoCoordinate) -> CGPoint? {
        guard let map else { return nil }
        return map.convert(coordinate.clLocation, toPointTo: map)
    }

    /// Drehen und Neigen beim Zeichnen sperren (die Zeichnung folgt nur Verschieben und Zoom).
    func setRotationEnabled(_ enabled: Bool) {
        map?.isRotateEnabled = enabled
        map?.isPitchEnabled = enabled
    }

    func coordinate(at point: CGPoint) -> GeoCoordinate? {
        guard let map else { return nil }
        let location = map.convert(point, toCoordinateFrom: map)
        return GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
    }
}

// MARK: - Kreise und Rechtecke

/// Beschriftung eines Kartenobjekts in seiner Mitte (antippbar zum Bearbeiten).
final class MapObjectAnnotation: NSObject, MKAnnotation {
    let objectID: MapObjectID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var color: RGBColor

    init(object: MapObject) {
        objectID = object.id
        coordinate = object.shape.center.clLocation
        title = object.displayName
        color = object.color
        super.init()
    }
}

/// Griff zum Ändern der Größe (Kreis: Ostrand, Rechteck: Südost-Ecke).
final class MapResizeHandle: NSObject, MKAnnotation {
    let objectID: MapObjectID
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(objectID: MapObjectID, coordinate: CLLocationCoordinate2D) {
        self.objectID = objectID
        self.coordinate = coordinate
        super.init()
    }

    /// Weißer Punkt mit Rand, groß genug zum Greifen (30 pt).
    @MainActor static let image: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
        let rect = CGRect(x: 3, y: 3, width: 24, height: 24)
        UIColor.white.setFill()
        context.cgContext.fillEllipse(in: rect)
        UIColor.systemBlue.setStroke()
        context.cgContext.setLineWidth(3)
        context.cgContext.strokeEllipse(in: rect)
        UIColor.systemBlue.setFill()
        context.cgContext.fillEllipse(in: rect.insetBy(dx: 8, dy: 8))
    }
}

/// Farben für Markierungen (wie ELRDRG: Rot als Standard).
enum MapObjectPalette {
    static let colors: [(name: String, color: RGBColor)] = [
        ("Rot", MapObject.defaultColor),
        ("Orange", RGBColor(hex: 0xF57C00)),
        ("Gelb", RGBColor(hex: 0xFBC02D)),
        ("Grün", RGBColor(hex: 0x388E3C)),
        ("Blau", RGBColor(hex: 0x1976D2)),
        ("Lila", RGBColor(hex: 0x7B1FA2)),
    ]

    /// Häufige Bezeichnungen zum Antippen.
    static let titles = ["Gefahrenbereich", "Sperrzone", "Landeplatz RTH", "Sammelstelle", "Behandlungsplatz", "Bereitstellungsraum"]

    /// Radien zum Antippen (Meter).
    static let radii: [Double] = [25, 50, 100, 250, 500, 1000]

    /// Rechteckgrößen zum Antippen (Breite × Höhe in Metern).
    static let rectangleSizes: [(width: Double, height: Double)] = [(30, 30), (50, 25), (100, 50), (200, 100), (500, 250)]

    /// Neue Formen um die Kartenmitte.
    static func newCircle(at center: GeoCoordinate) -> MapShape { .circle(center: center, radiusMeters: 100) }

    static func newRectangle(at center: GeoCoordinate) -> MapShape? {
        GeoBounds.around(center, widthMeters: 100, heightMeters: 50).map { .rectangle(bounds: $0) }
    }

    /// Größer/kleiner um ein Viertel; Kreis bleibt im erlaubten Radius.
    static func scaled(_ shape: MapShape, by factor: Double) -> MapShape {
        switch shape {
        case let .circle(center, radius):
            let next = min(max(radius * factor, MapShape.radiusRange.lowerBound), MapShape.radiusRange.upperBound)
            return .circle(center: center, radiusMeters: next.rounded())
        case let .rectangle(bounds):
            guard let next = GeoBounds.around(bounds.center, widthMeters: bounds.widthMeters * factor, heightMeters: bounds.heightMeters * factor) else { return shape }
            return .rectangle(bounds: next)
        case .drawing:
            return shape
        }
    }
}

extension UIColor {
    convenience init(_ rgb: RGBColor) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
