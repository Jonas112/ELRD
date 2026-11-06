import Foundation
import MapKit
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

    func coordinate(at point: CGPoint) -> GeoCoordinate? {
        guard let map else { return nil }
        let location = map.convert(point, toCoordinateFrom: map)
        return GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
    }
}
