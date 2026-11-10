import MapKit
import UIKit
import ELRDDomain
import ELRDStore

// MARK: - Fotos mit Aufnahmeort (Schritt 111)

/// Foto aus dem Tagebuch, das einen Aufnahmeort hat.
struct MapPhotoPin: Identifiable, Equatable {
    let id: AttachmentID
    let file: FileAttachment
    let coordinate: GeoCoordinate
    let title: String

    /// Alle Fotos aktiver Tagebucheinträge mit Ort (ohne Kartenausschnitte).
    static func pins(for state: MissionState) -> [MapPhotoPin] {
        state.journal.active
            .filter { $0.origin != .mapSnapshot }
            .flatMap { entry in
                entry.attachments.compactMap { file -> MapPhotoPin? in
                    guard file.kind == .photo, let coordinate = file.coordinate else { return nil }
                    let time = entry.occurredAt.formatted(date: .omitted, time: .shortened)
                    return MapPhotoPin(id: file.id, file: file, coordinate: coordinate, title: "Foto \(entry.number), \(time) Uhr")
                }
            }
    }
}

final class PhotoAnnotation: NSObject, MKAnnotation {
    let pin: MapPhotoPin
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(pin: MapPhotoPin) {
        self.pin = pin
        coordinate = pin.coordinate.clLocation
        title = pin.title
        super.init()
    }
}

// MARK: - Taktische Zeichen (Schritt 114)

final class TacticalSignAnnotation: NSObject, MKAnnotation {
    let objectID: MapObjectID
    let sign: TacticalSign
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(object: MapObject, sign: TacticalSign) {
        objectID = object.id
        self.sign = sign
        coordinate = object.shape.center.clLocation
        title = object.displayName
        super.init()
    }
}

// MARK: - Polygon und Pfeil (Schritt 115)

/// Linienzug mit Pfeilspitze am letzten Punkt.
final class ArrowPolyline: MKPolyline {}
/// Vorschau beim Setzen (gestrichelt).
final class DraftPolyline: MKPolyline {}
final class DraftPolygon: MKPolygon {}
final class DraftPointAnnotation: MKPointAnnotation {}

/// Zeichnet Linie und eine Pfeilspitze in fester Bildschirmgröße.
final class ArrowRenderer: MKPolylineRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        let count = polyline.pointCount
        guard count >= 2 else { return }
        let points = polyline.points()
        let tip = point(for: points[count - 1])
        let from = point(for: points[count - 2])
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let length = 26 / zoomScale
        let spread = CGFloat.pi / 7
        let left = CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread))
        let right = CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.setFillColor((strokeColor ?? .systemRed).cgColor)
        context.fillPath()
    }
}
