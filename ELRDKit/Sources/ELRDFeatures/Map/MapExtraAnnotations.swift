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

/// Taktisches Zeichen, das sich verschieben lässt (Schritte 121/122/124): kurz gedrückt
/// halten, dann ziehen. Ein einfacher Tipp (eigener Erkenner, erst wenn das Halten
/// scheitert) öffnet die Bearbeitung; nach dem Verschieben nicht. Während des Ziehens steht die Karte still.
@MainActor
final class TacticalSignAnnotationView: MKAnnotationView, UIGestureRecognizerDelegate {
    var allowsMoving = false
    var onMoved: ((MapObjectID, GeoCoordinate) -> Void)?
    /// Schritt 124: einfacher Tipp öffnet die Bearbeitung (nicht MapKits Auswahl).
    var onTap: ((MapObjectID) -> Void)?
    /// Gerade gezogen bzw. eben losgelassen – dann keine Bearbeitung öffnen.
    private(set) var isMoving = false
    private var movedAt: Date?

    var suppressesSelection: Bool {
        isMoving || (movedAt.map { Date().timeIntervalSince($0) < 0.6 } ?? false)
    }

    private lazy var press: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        recognizer.delegate = self
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 12
        return recognizer
    }()
    /// Abstand Finger → Ankerpunkt beim Greifen (Zeichen springt nicht unter den Finger).
    private var grabOffset: CGPoint = .zero
    private var startCoordinate: CLLocationCoordinate2D?
    private weak var map: MKMapView?

    private lazy var tap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.delegate = self
        recognizer.require(toFail: press)
        return recognizer
    }()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setUpGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpGestures()
    }

    private func setUpGestures() {
        addGestureRecognizer(press)
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, !suppressesSelection, let sign = annotation as? TacticalSignAnnotation else { return }
        onTap?(sign.objectID)
    }

    override func accessibilityActivate() -> Bool {
        guard let sign = annotation as? TacticalSignAnnotation, let onTap else { return false }
        onTap(sign.objectID)
        return true
    }

    private func mapView() -> MKMapView? {
        if let map { return map }
        var current = superview
        while let view = current {
            if let found = view as? MKMapView {
                map = found
                return found
            }
            current = view.superview
        }
        return nil
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === tap { return annotation is TacticalSignAnnotation }
        guard recognizer === press else { return super.gestureRecognizerShouldBegin(recognizer) }
        return allowsMoving && annotation is TacticalSignAnnotation
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        guard let map = mapView(), let sign = annotation as? TacticalSignAnnotation else { return }
        let finger = recognizer.location(in: map)
        switch recognizer.state {
        case .began:
            isMoving = true
            startCoordinate = sign.coordinate
            let anchor = map.convert(sign.coordinate, toPointTo: map)
            grabOffset = CGPoint(x: anchor.x - finger.x, y: anchor.y - finger.y)
            map.isScrollEnabled = false
            map.isZoomEnabled = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIView.animate(withDuration: 0.12) {
                self.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
                self.alpha = 0.85
            }
        case .changed:
            let point = CGPoint(x: finger.x + grabOffset.x, y: finger.y + grabOffset.y)
            sign.coordinate = map.convert(point, toCoordinateFrom: map)
        case .ended:
            finish(map)
            let coordinate = sign.coordinate
            if let start = startCoordinate, start.latitude == coordinate.latitude, start.longitude == coordinate.longitude { return }
            if let moved = GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) {
                onMoved?(sign.objectID, moved)
            }
        case .cancelled, .failed:
            finish(map)
            if let startCoordinate { sign.coordinate = startCoordinate }
        default:
            break
        }
    }

    private func finish(_ map: MKMapView) {
        isMoving = false
        movedAt = Date()
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        UIView.animate(withDuration: 0.12) {
            self.transform = .identity
            self.alpha = 1
        }
    }

    /// Neben MapKits eigenen Erkennern (Auswahl, Doppeltipp-Zoom) laufen lassen, damit
    /// sie das Gedrückthalten nicht verdrängen. Während des Ziehens steht die Karte still.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view !== self
    }
}
