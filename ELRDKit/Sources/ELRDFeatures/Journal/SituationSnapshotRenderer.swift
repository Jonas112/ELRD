import Foundation
import MapKit
import UIKit
import ELRDDomain
import ELRDStore
import ELRDPersistence

/// Kartenbild für das automatische Lagebild (Schritt 109): Kartenausschnitt um
/// Einsatzort, Abschnitte und Markierungen, darauf Kreise, Rechtecke, Zeichnungen
/// und Abschnittspunkte. Unabhängig davon, ob die Karte gerade offen ist.
enum SituationSnapshotRenderer {
    struct Output: Sendable {
        let jpeg: Data
        let width: Int
        let height: Int
    }

    /// Was auf das Bild kommt – vorab gesammelt, damit das Zeichnen ohne Zugriff
    /// auf Store und Dateien auskommt.
    struct Overlay: Sendable {
        enum Kind: Sendable {
            case circle(center: GeoCoordinate, radiusMeters: Double)
            case rectangle(GeoBounds)
            case image(GeoBounds, Data)
            case section(GeoCoordinate)
            case mission(GeoCoordinate)
            case sign(GeoCoordinate, TacticalSign)
            case path(MapPath)
        }

        let kind: Kind
        let color: RGBColor
        let title: String
    }

    static let size = CGSize(width: 1200, height: 800)

    /// Lagebild erstellen und ins Tagebuch schreiben (automatisch oder per Tipp).
    /// Ohne Einsatzort oder ohne Kartenbild nur als Text.
    @MainActor
    @discardableResult
    static func capture(
        store: MissionStore,
        settings: AppSettings,
        attachments: AttachmentFileStore,
        minimumGap: TimeInterval = 0,
        now: Date = Date()
    ) async throws -> JournalEntry? {
        let state = store.state
        let openItems = OpenItem.items(for: state, now: now, reminders: settings.reminders)
        let text = SituationSnapshot.text(state, openItemCount: openItems.count, now: now)
        let header = text.components(separatedBy: "\n").first ?? "Lagebild"
        var image: FileAttachment?
        if let output = await render(state, header: header, attachments: attachments) {
            image = try? attachments.save(output.jpeg, kind: .photo, createdAt: now, pixelWidth: output.width, pixelHeight: output.height)
        }
        return try store.perform(AddSituationSnapshot(text: text, image: image, minimumGap: minimumGap))
    }

    /// `nil` ohne Koordinaten (dann nur Text) oder wenn MapKit kein Bild liefert.
    @MainActor
    static func render(_ state: MissionState, header: String, attachments: AttachmentFileStore) async -> Output? {
        let overlays = overlays(state, attachments: attachments)
        guard let region = region(for: overlays) else { return nil }
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection { traits in
            traits.displayScale = 1
            traits.userInterfaceStyle = .light
        }
        let snapshotter = MKMapSnapshotter(options: options)
        let output: Output? = await withCheckedContinuation { continuation in
            snapshotter.start(with: .global(qos: .utility)) { snapshot, _ in
                guard let snapshot else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: draw(snapshot, overlays: overlays, header: header))
            }
        }
        withExtendedLifetime(snapshotter) {}
        return output
    }

    // MARK: Inhalt

    static func overlays(_ state: MissionState, attachments: AttachmentFileStore) -> [Overlay] {
        var result: [Overlay] = []
        for object in state.mapObjects.active {
            if let sign = object.tacticalSign {
                result.append(Overlay(kind: .sign(object.shape.center, sign), color: object.color, title: ""))
                continue
            }
            if let path = object.path {
                result.append(Overlay(kind: .path(path), color: object.color, title: object.title))
                continue
            }
            switch object.shape {
            case let .circle(center, radius):
                result.append(Overlay(kind: .circle(center: center, radiusMeters: radius), color: object.color, title: object.title))
            case let .rectangle(bounds):
                result.append(Overlay(kind: .rectangle(bounds), color: object.color, title: object.title))
            case let .drawing(bounds, image):
                guard let data = attachments.data(for: image) else { continue }
                result.append(Overlay(kind: .image(bounds, data), color: object.color, title: object.title))
            }
        }
        for section in state.sections.active {
            guard let coordinate = section.coordinate else { continue }
            result.append(Overlay(kind: .section(coordinate), color: RGBColor(hex: 0x1976D2), title: section.name))
        }
        if let coordinate = state.mission.coordinate {
            result.append(Overlay(kind: .mission(coordinate), color: MapObject.defaultColor, title: "Einsatzort"))
        }
        return result
    }

    /// Ausschnitt um alle Punkte mit Rand; mindestens etwa 600 m hoch.
    static func region(for overlays: [Overlay]) -> MKCoordinateRegion? {
        var latitudes: [Double] = []
        var longitudes: [Double] = []
        func addCoordinate(_ coordinate: GeoCoordinate) {
            latitudes.append(coordinate.latitude)
            longitudes.append(coordinate.longitude)
        }
        func addBounds(_ bounds: GeoBounds) {
            latitudes += [bounds.north, bounds.south]
            longitudes += [bounds.east, bounds.west]
        }
        for overlay in overlays {
            switch overlay.kind {
            case let .circle(center, radius):
                let dLat = radius / 111_320
                let dLon = radius / max(1, 111_320 * cos(center.latitude * .pi / 180))
                latitudes += [center.latitude - dLat, center.latitude + dLat]
                longitudes += [center.longitude - dLon, center.longitude + dLon]
            case let .rectangle(bounds), let .image(bounds, _):
                addBounds(bounds)
            case let .section(coordinate), let .mission(coordinate), let .sign(coordinate, _):
                addCoordinate(coordinate)
            case let .path(path):
                path.points.forEach(addCoordinate)
            }
        }
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max() else { return nil }
        let center = CLLocationCoordinate2D(latitude: (north + south) / 2, longitude: (east + west) / 2)
        let minimumLat = 0.0055
        let latSpan = min(170, max(minimumLat, (north - south) * 1.4))
        let lonFactor = max(0.1, cos(center.latitude * .pi / 180))
        let lonSpan = min(350, max(minimumLat * 1.5 / lonFactor, (east - west) * 1.4))
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
    }

    // MARK: Zeichnen

    private static func draw(_ snapshot: MKMapSnapshotter.Snapshot, overlays: [Overlay], header: String) -> Output? {
        let base = snapshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = base.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: base.size, format: format)
        func point(_ coordinate: GeoCoordinate) -> CGPoint {
            snapshot.point(for: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        func rect(_ bounds: GeoBounds) -> CGRect? {
            guard let topLeft = GeoCoordinate(latitude: bounds.north, longitude: bounds.west),
                  let bottomRight = GeoCoordinate(latitude: bounds.south, longitude: bounds.east) else { return nil }
            let a = point(topLeft), b = point(bottomRight)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        let image = renderer.image { context in
            base.draw(at: .zero)
            let cg = context.cgContext
            for overlay in overlays {
                let color = UIColor(overlay.color)
                switch overlay.kind {
                case let .circle(center, radius):
                    let c = point(center)
                    guard let edge = GeoCoordinate(latitude: min(90, center.latitude + radius / 111_320), longitude: center.longitude) else { continue }
                    let r = max(4, abs(c.y - point(edge).y))
                    let path = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    color.withAlphaComponent(0.18).setFill()
                    path.fill()
                    color.setStroke()
                    path.lineWidth = 3
                    path.stroke()
                    label(overlay.title, at: CGPoint(x: c.x, y: c.y - r - 4), color: color)
                case let .rectangle(bounds):
                    guard let frame = rect(bounds) else { continue }
                    let path = UIBezierPath(rect: frame)
                    color.withAlphaComponent(0.18).setFill()
                    path.fill()
                    color.setStroke()
                    path.lineWidth = 3
                    path.stroke()
                    label(overlay.title, at: CGPoint(x: frame.midX, y: frame.minY - 4), color: color)
                case let .image(bounds, data):
                    guard let frame = rect(bounds), let drawing = UIImage(data: data) else { continue }
                    drawing.draw(in: frame)
                case let .section(coordinate):
                    let p = point(coordinate)
                    dot(at: p, radius: 9, color: color, in: cg)
                    label(overlay.title, at: CGPoint(x: p.x, y: p.y - 12), color: color)
                case let .mission(coordinate):
                    let p = point(coordinate)
                    dot(at: p, radius: 12, color: color, in: cg)
                    label(overlay.title, at: CGPoint(x: p.x, y: p.y - 15), color: color)
                case let .sign(coordinate, sign):
                    let p = point(coordinate)
                    let units = TacticalSignRenderer.unitSize(of: sign)
                    let scale = 40 / units.height
                    TacticalSignRenderer.draw(sign, in: cg, origin: CGPoint(x: p.x - units.width * scale / 2, y: p.y - units.height * scale / 2), scale: scale)
                case let .path(path):
                    let points = path.points.map(point)
                    guard let first = points.first else { continue }
                    let line = UIBezierPath()
                    line.move(to: first)
                    points.dropFirst().forEach { line.addLine(to: $0) }
                    if path.kind == .polygon {
                        line.close()
                        color.withAlphaComponent(0.18).setFill()
                        line.fill()
                    } else if points.count >= 2 {
                        let tip = points[points.count - 1], from = points[points.count - 2]
                        let angle = atan2(tip.y - from.y, tip.x - from.x)
                        let head = UIBezierPath()
                        head.move(to: tip)
                        head.addLine(to: CGPoint(x: tip.x - 24 * cos(angle - .pi / 7), y: tip.y - 24 * sin(angle - .pi / 7)))
                        head.addLine(to: CGPoint(x: tip.x - 24 * cos(angle + .pi / 7), y: tip.y - 24 * sin(angle + .pi / 7)))
                        head.close()
                        color.setFill()
                        head.fill()
                    }
                    color.setStroke()
                    line.lineWidth = path.kind == .arrow ? 5 : 3
                    line.stroke()
                    if let anchor = points.first { label(overlay.title, at: CGPoint(x: anchor.x, y: anchor.y - 6), color: color) }
                }
            }
            headerBar(header, width: base.size.width)
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        return Output(jpeg: jpeg, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale))
    }

    private static func dot(at point: CGPoint, radius: CGFloat, color: UIColor, in context: CGContext) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect)
    }

    /// Beschriftung mit hellem Hintergrund, unten mittig an `point`.
    private static func label(_ text: String, at point: CGPoint, color: UIColor) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: UIColor.black,
        ]
        let size = (trimmed as NSString).size(withAttributes: attributes)
        let box = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height - 4, width: size.width + 12, height: size.height + 4)
        UIColor.white.withAlphaComponent(0.88).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 6).fill()
        color.setStroke()
        let border = UIBezierPath(roundedRect: box, cornerRadius: 6)
        border.lineWidth = 2
        border.stroke()
        (trimmed as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
    }

    private static func headerBar(_ text: String, width: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .heavy),
            .foregroundColor: UIColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: 0, y: 0, width: width, height: size.height + 16)
        UIColor.black.withAlphaComponent(0.65).setFill()
        UIBezierPath(rect: box).fill()
        (text as NSString).draw(at: CGPoint(x: 16, y: 8), withAttributes: attributes)
    }
}
