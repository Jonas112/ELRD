import SwiftUI
import MapKit
import ELRDDomain

/// Auftrag, die Karte auf ein Ziel zu bewegen. Jede Anfrage hat eine eigene
/// Kennung, damit derselbe Knopf mehrmals wirkt.
struct MapFocusRequest: Equatable {
    enum Target: Equatable {
        case coordinate(GeoCoordinate)
        case user
    }

    let id = UUID()
    let target: Target
}

/// MapKit-Karte (UIKit), weil die SwiftUI-`Map` unter iPadOS 17 keine Kachel-
/// Overlays (OSM/OpenTopoMap) kann. Maßstab ist immer sichtbar.
struct MapCanvas: UIViewRepresentable {
    let layer: MapBaseLayer
    let missionCoordinate: GeoCoordinate?
    let missionTitle: String
    let showsUserLocation: Bool
    let focus: MapFocusRequest?
    /// Abschnitte; nur die mit Koordinate erscheinen auf der Karte.
    var sections: [MapSectionPin] = []
    /// Abschnitte lassen sich auf der Karte verschieben.
    var canEdit = false
    var proxy: MapCanvasProxy?
    /// Kartenmitte nach jeder Bewegung (zum Setzen des Einsatzorts).
    var onCenterChange: (GeoCoordinate) -> Void = { _ in }
    /// Abschnitt wurde auf der Karte verschoben.
    var onMoveSection: (SectionID, GeoCoordinate) -> Void = { _, _ in }
    /// Kreise und Rechtecke (aktive).
    var objects: [MapObject] = []
    /// Beschriftung eines Kartenobjekts angetippt.
    var onSelectObject: (MapObjectID) -> Void = { _ in }

    /// Ausschnitt um den Einsatzort (mindestens ca. 800 m) und alles, was schon
    /// auf der Karte liegt (mit Rand); ohne Einsatzort ganz Deutschland.
    static func initialRegion(around coordinate: GeoCoordinate?, including others: [GeoCoordinate] = []) -> MKCoordinateRegion {
        if let coordinate {
            let points = [coordinate] + others
            let north = points.map(\.latitude).max() ?? coordinate.latitude
            let south = points.map(\.latitude).min() ?? coordinate.latitude
            let east = points.map(\.longitude).max() ?? coordinate.longitude
            let west = points.map(\.longitude).min() ?? coordinate.longitude
            let minimum = MKCoordinateRegion(center: coordinate.clLocation, latitudinalMeters: 800, longitudinalMeters: 800).span
            let span = MKCoordinateSpan(
                latitudeDelta: max((north - south) * 1.6, minimum.latitudeDelta),
                longitudeDelta: max((east - west) * 1.6, minimum.longitudeDelta)
            )
            let middle = CLLocationCoordinate2D(latitude: (north + south) / 2, longitude: (east + west) / 2)
            return MKCoordinateRegion(center: others.isEmpty ? coordinate.clLocation : middle, span: span)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.16, longitude: 10.45),
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll

        let scale = MKScaleView(mapView: map)
        scale.scaleVisibility = .visible
        scale.legendAlignment = .leading
        scale.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(scale)
        NSLayoutConstraint.activate([
            scale.leadingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            scale.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])

        proxy?.map = map
        context.coordinator.onCenterChange = onCenterChange
        context.coordinator.onMoveSection = onMoveSection
        context.coordinator.canEdit = canEdit
        let placed = sections.compactMap(\.coordinate) + objects.map(\.shape.center)
        map.setRegion(Self.initialRegion(around: missionCoordinate, including: placed), animated: false)
        context.coordinator.apply(layer: layer, to: map)
        context.coordinator.updateMissionMarker(missionCoordinate, title: missionTitle, on: map)
        context.coordinator.onSelectObject = onSelectObject
        context.coordinator.updateSections(sections, on: map)
        context.coordinator.updateObjects(objects, on: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        proxy?.map = map
        coordinator.onCenterChange = onCenterChange
        coordinator.onMoveSection = onMoveSection
        coordinator.canEdit = canEdit
        coordinator.apply(layer: layer, to: map)
        coordinator.updateMissionMarker(missionCoordinate, title: missionTitle, on: map)
        coordinator.onSelectObject = onSelectObject
        coordinator.updateSections(sections, on: map)
        coordinator.updateObjects(objects, on: map)
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }
        if let focus, focus.id != coordinator.lastFocusID {
            coordinator.lastFocusID = focus.id
            switch focus.target {
            case .coordinate(let target):
                map.setUserTrackingMode(.none, animated: false)
                map.setRegion(MKCoordinateRegion(center: target.clLocation, latitudinalMeters: 800, longitudinalMeters: 800), animated: true)
            case .user:
                map.showsUserLocation = true
                map.setUserTrackingMode(.follow, animated: true)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var currentLayer: MapBaseLayer?
        private var tileOverlay: MKTileOverlay?
        private var marker: MKPointAnnotation?
        var lastFocusID: UUID?
        var onCenterChange: (GeoCoordinate) -> Void = { _ in }
        var onMoveSection: (SectionID, GeoCoordinate) -> Void = { _, _ in }
        var canEdit = false
        private var sectionAnnotations: [SectionID: SectionAnnotation] = [:]
        var onSelectObject: (MapObjectID) -> Void = { _ in }
        /// Gezeichnete Objekte: Stand, Fläche und Beschriftung je Kennung.
        private var drawn: [MapObjectID: (object: MapObject, overlay: any MKOverlay, label: MapObjectAnnotation)] = [:]
        /// Farbe je Fläche (für den Renderer).
        private var overlayColors: [ObjectIdentifier: RGBColor] = [:]

        /// Gleicht Kreise und Rechtecke ab; geänderte werden neu gezeichnet.
        func updateObjects(_ objects: [MapObject], on map: MKMapView) {
            let wanted = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, entry) in drawn {
                let current = wanted[id]
                let unchanged = current.map { $0.shape == entry.object.shape && $0.color == entry.object.color && $0.displayName == entry.object.displayName } ?? false
                guard !unchanged else { continue }
                map.removeOverlay(entry.overlay)
                map.removeAnnotation(entry.label)
                overlayColors[ObjectIdentifier(entry.overlay)] = nil
                drawn[id] = nil
            }
            for object in objects where drawn[object.id] == nil {
                guard let overlay = Self.overlay(for: object.shape) else { continue }
                let label = MapObjectAnnotation(object: object)
                overlayColors[ObjectIdentifier(overlay)] = object.color
                map.addOverlay(overlay, level: .aboveLabels)
                map.addAnnotation(label)
                drawn[object.id] = (object, overlay, label)
            }
        }

        static func overlay(for shape: MapShape) -> (any MKOverlay)? {
            switch shape {
            case let .circle(center, radius):
                return MKCircle(center: center.clLocation, radius: radius)
            case let .rectangle(bounds):
                var corners = [
                    CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west),
                    CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.east),
                    CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east),
                    CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.west),
                ]
                return MKPolygon(coordinates: &corners, count: corners.count)
            case .drawing:
                return nil // Schritt 31
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let label = view.annotation as? MapObjectAnnotation else { return }
            mapView.deselectAnnotation(label, animated: false)
            onSelectObject(label.objectID)
        }

        /// Gleicht die Abschnittsmarkierungen mit dem Stand ab (nur Änderungen).
        func updateSections(_ pins: [MapSectionPin], on map: MKMapView) {
            let placed = pins.filter { $0.coordinate != nil }
            let wanted = Set(placed.map(\.id))
            for (id, annotation) in sectionAnnotations where !wanted.contains(id) {
                map.removeAnnotation(annotation)
                sectionAnnotations[id] = nil
            }
            for pin in placed {
                guard let position = pin.coordinate?.clLocation else { continue }
                let subtitle = pin.summary.isEmpty ? nil : pin.summary
                if let existing = sectionAnnotations[pin.id] {
                    if existing.coordinate.latitude != position.latitude || existing.coordinate.longitude != position.longitude {
                        existing.coordinate = position
                    }
                    if existing.title != pin.name { existing.title = pin.name }
                    if existing.subtitle != subtitle { existing.subtitle = subtitle }
                    if let view = map.view(for: existing) { view.isDraggable = canEdit }
                } else {
                    let created = SectionAnnotation(pin: pin, coordinate: position)
                    sectionAnnotations[pin.id] = created
                    map.addAnnotation(created)
                }
            }
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            switch newState {
            case .ending:
                view.setDragState(.none, animated: true)
                if let annotation = view.annotation as? SectionAnnotation,
                   let moved = GeoCoordinate(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude) {
                    onMoveSection(annotation.sectionID, moved)
                }
            case .canceling:
                view.setDragState(.none, animated: true)
            default:
                break
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            if let coordinate = GeoCoordinate(latitude: center.latitude, longitude: center.longitude) {
                onCenterChange(coordinate)
            }
        }

        func apply(layer: MapBaseLayer, to map: MKMapView) {
            guard layer != currentLayer else { return }
            currentLayer = layer
            if let tileOverlay { map.removeOverlay(tileOverlay) }
            tileOverlay = nil
            switch layer {
            case .apple: map.mapType = .standard
            case .satellite: map.mapType = .satellite
            case .hybrid: map.mapType = .hybrid
            case .openStreetMap, .openTopoMap: map.mapType = .standard
            }
            if let template = layer.tileTemplate {
                let overlay = MKTileOverlay(urlTemplate: template)
                overlay.canReplaceMapContent = true
                overlay.maximumZ = layer.maximumZoom
                map.addOverlay(overlay, level: .aboveLabels)
                tileOverlay = overlay
            }
        }

        func updateMissionMarker(_ coordinate: GeoCoordinate?, title: String, on map: MKMapView) {
            guard let coordinate else {
                if let marker { map.removeAnnotation(marker) }
                marker = nil
                return
            }
            if let marker {
                if marker.coordinate.latitude != coordinate.latitude || marker.coordinate.longitude != coordinate.longitude {
                    marker.coordinate = coordinate.clLocation
                }
                if marker.title != title { marker.title = title }
                return
            }
            let created = MKPointAnnotation()
            created.coordinate = coordinate.clLocation
            created.title = title
            map.addAnnotation(created)
            marker = created
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            let color = UIColor(overlayColors[ObjectIdentifier(overlay)] ?? MapObject.defaultColor)
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = color.withAlphaComponent(0.18)
                renderer.strokeColor = color
                renderer.lineWidth = 3
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = color.withAlphaComponent(0.18)
                renderer.strokeColor = color
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let label = annotation as? MapObjectAnnotation {
                let identifier = "object"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: label, reuseIdentifier: identifier)
                view.annotation = label
                view.markerTintColor = UIColor(label.color)
                view.glyphImage = UIImage(systemName: "pencil")
                view.titleVisibility = .visible
                view.displayPriority = .defaultHigh
                view.isDraggable = false
                return view
            }
            if let section = annotation as? SectionAnnotation {
                let identifier = "section"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: section, reuseIdentifier: identifier)
                view.annotation = section
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "square.stack.3d.up.fill")
                view.titleVisibility = .visible
                view.subtitleVisibility = .adaptive
                view.displayPriority = .required
                view.isDraggable = canEdit
                return view
            }
            guard annotation === marker else { return nil }
            let identifier = "mission"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "flag.fill")
            view.displayPriority = .required
            view.titleVisibility = .visible
            return view
        }
    }
}

extension GeoCoordinate {
    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
