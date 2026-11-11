import SwiftUI
import MapKit
import ELRDDomain
import ELRDPersistence

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
    /// Objekt an seiner Beschriftung verschoben (Schritt 60).
    var onMoveObject: (MapObjectID, GeoCoordinate) -> Void = { _, _ in }
    /// Griff eines Objekts gezogen: neue Größe (Schritt 60).
    var onResizeObject: (MapObjectID, GeoCoordinate) -> Void = { _, _ in }
    /// Dateiablage für Zeichnungen.
    var attachments: AttachmentFileStore?
    /// Fahne des Einsatzorts verschoben (Schritt 79).
    var onMoveMission: (GeoCoordinate) -> Void = { _ in }
    /// Ausschnitt ändert sich gerade (laufend, z. B. für die Zeichenfläche).
    var onRegionChanging: () -> Void = {}
    /// Fotos mit Aufnahmeort (Schritt 111).
    var photos: [MapPhotoPin] = []
    var onSelectPhoto: (MapPhotoPin) -> Void = { _ in }
    /// Punkte eines Polygons/Pfeils, der gerade gesetzt wird (Schritt 115).
    var pathDraft: MapPath?
    /// Tippen auf die Karte (nur beim Setzen von Punkten, Schritt 115).
    var onTapMap: ((GeoCoordinate) -> Void)?

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
        context.coordinator.onMoveObject = onMoveObject
        context.coordinator.onResizeObject = onResizeObject
        context.coordinator.onMoveMission = onMoveMission
        context.coordinator.onRegionChanging = onRegionChanging
        context.coordinator.attachments = attachments
        context.coordinator.updateSections(sections, on: map)
        context.coordinator.updateObjects(objects, on: map)
        context.coordinator.updatePhotos(photos, on: map)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
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
        coordinator.onMoveObject = onMoveObject
        coordinator.onResizeObject = onResizeObject
        coordinator.onMoveMission = onMoveMission
        coordinator.onRegionChanging = onRegionChanging
        coordinator.attachments = attachments
        coordinator.updateSections(sections, on: map)
        coordinator.updateObjects(objects, on: map)
        coordinator.onSelectPhoto = onSelectPhoto
        coordinator.onTapMap = onTapMap
        coordinator.updatePhotos(photos, on: map)
        coordinator.updatePathDraft(pathDraft, on: map)
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
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onTapMap: ((GeoCoordinate) -> Void)?

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let onTapMap, recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            if let tapped = GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) { onTapMap(tapped) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Nur beim Setzen von Punkten – sonst bleiben Tipps bei der Karte.
            gestureRecognizer is UITapGestureRecognizer ? onTapMap != nil : true
        }

        private var currentLayer: MapBaseLayer?
        private var tileOverlay: MKTileOverlay?
        private var marker: MKPointAnnotation?
        var lastFocusID: UUID?
        var onCenterChange: (GeoCoordinate) -> Void = { _ in }
        var onMoveSection: (SectionID, GeoCoordinate) -> Void = { _, _ in }
        var canEdit = false
        private var sectionAnnotations: [SectionID: SectionAnnotation] = [:]
        var onSelectObject: (MapObjectID) -> Void = { _ in }
        var onMoveObject: (MapObjectID, GeoCoordinate) -> Void = { _, _ in }
        var onResizeObject: (MapObjectID, GeoCoordinate) -> Void = { _, _ in }
        var onMoveMission: (GeoCoordinate) -> Void = { _ in }
        var onRegionChanging: () -> Void = {}
        var attachments: AttachmentFileStore?
        var onSelectPhoto: (MapPhotoPin) -> Void = { _ in }
        private var photoAnnotations: [AttachmentID: PhotoAnnotation] = [:]
        private var draftOverlay: (any MKOverlay)?
        private var draftPoints: [MKPointAnnotation] = []
        private var currentDraft: MapPath?
        /// Gezeichnete Objekte: Stand, Fläche (fehlt bei taktischen Zeichen), Beschriftung
        /// bzw. Zeichen und Größen-Griff je Kennung.
        private var drawn: [MapObjectID: (object: MapObject, overlay: (any MKOverlay)?, label: any MKAnnotation, handle: MapResizeHandle?)] = [:]
        /// Bearbeiten erlaubt, als die Objekte gezeichnet wurden (Griffe nur dann).
        private var drawnWithEditing = false
        /// Farbe je Fläche (für den Renderer).
        private var overlayColors: [ObjectIdentifier: RGBColor] = [:]

        /// Gleicht Kreise und Rechtecke ab; geänderte werden neu gezeichnet.
        func updateObjects(_ objects: [MapObject], on map: MKMapView) {
            let wanted = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let editingChanged = drawnWithEditing != canEdit
            drawnWithEditing = canEdit
            for (id, entry) in drawn {
                let current = wanted[id]
                let unchanged = current.map {
                    $0.shape == entry.object.shape && $0.color == entry.object.color && $0.displayName == entry.object.displayName
                        && $0.tacticalSign == entry.object.tacticalSign && $0.path == entry.object.path
                } ?? false
                guard !unchanged || editingChanged else { continue }
                if let overlay = entry.overlay {
                    map.removeOverlay(overlay)
                    overlayColors[ObjectIdentifier(overlay)] = nil
                }
                map.removeAnnotation(entry.label)
                if let handle = entry.handle { map.removeAnnotation(handle) }
                drawn[id] = nil
            }
            for object in objects where drawn[object.id] == nil {
                // Schritt 114: taktisches Zeichen als Bild am Standort, ohne Fläche.
                if let sign = object.tacticalSign {
                    let annotation = TacticalSignAnnotation(object: object, sign: sign)
                    map.addAnnotation(annotation)
                    drawn[object.id] = (object, nil, annotation, nil)
                    continue
                }
                guard let shapeOverlay = makeOverlay(for: object) else { continue }
                let label = MapObjectAnnotation(object: object)
                overlayColors[ObjectIdentifier(shapeOverlay)] = object.color
                map.addOverlay(shapeOverlay, level: .aboveLabels)
                map.addAnnotation(label)
                var handle: MapResizeHandle?
                if canEdit, object.isResizable, let position = object.shape.resizeHandle {
                    let created = MapResizeHandle(objectID: object.id, coordinate: position.clLocation)
                    map.addAnnotation(created)
                    handle = created
                }
                drawn[object.id] = (object, shapeOverlay, label, handle)
            }
        }

        func makeOverlay(for object: MapObject) -> (any MKOverlay)? {
            // Schritt 115: Polygon und Pfeil aus ihren Punkten.
            if let path = object.path {
                var points = path.points.map(\.clLocation)
                switch path.kind {
                case .polygon: return MKPolygon(coordinates: &points, count: points.count)
                case .arrow: return ArrowPolyline(coordinates: &points, count: points.count)
                }
            }
            return makeOverlay(for: object.shape)
        }

        func makeOverlay(for shape: MapShape) -> (any MKOverlay)? {
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
            case let .drawing(bounds, file):
                let image = attachments?.data(for: file).flatMap { UIImage(data: $0)?.cgImage }
                return DrawingOverlay(bounds: bounds, image: image)
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let photo = view.annotation as? PhotoAnnotation {
                mapView.deselectAnnotation(photo, animated: false)
                onSelectPhoto(photo.pin)
                return
            }
            if let sign = view.annotation as? TacticalSignAnnotation {
                // Schritt 124: MapKit wählt schon beim Berühren aus – dann öffnete sich die
                // Bearbeitung, bevor das Gedrückthalten greifen konnte. Zeichen öffnen die
                // Bearbeitung deshalb nur über ihren eigenen Tipp-Erkenner.
                mapView.deselectAnnotation(sign, animated: false)
                if !(view is TacticalSignAnnotationView) { onSelectObject(sign.objectID) }
                return
            }
            guard let label = view.annotation as? MapObjectAnnotation else { return }
            mapView.deselectAnnotation(label, animated: false)
            onSelectObject(label.objectID)
        }

        /// Fotos mit Aufnahmeort (Schritt 111) abgleichen.
        func updatePhotos(_ pins: [MapPhotoPin], on map: MKMapView) {
            let wanted = Set(pins.map(\.id))
            for (id, annotation) in photoAnnotations where !wanted.contains(id) {
                map.removeAnnotation(annotation)
                photoAnnotations[id] = nil
            }
            for pin in pins where photoAnnotations[pin.id] == nil {
                let annotation = PhotoAnnotation(pin: pin)
                photoAnnotations[pin.id] = annotation
                map.addAnnotation(annotation)
            }
        }

        /// Vorschau des Polygons/Pfeils, der gerade gesetzt wird (Schritt 115).
        func updatePathDraft(_ path: MapPath?, on map: MKMapView) {
            guard path != currentDraft else { return }
            currentDraft = path
            if let draftOverlay { map.removeOverlay(draftOverlay) }
            draftOverlay = nil
            map.removeAnnotations(draftPoints)
            draftPoints = []
            guard let path, !path.points.isEmpty else { return }
            var points = path.points.map(\.clLocation)
            if points.count >= 2 {
                let count = points.count
                let overlay: any MKOverlay
                if path.kind == .polygon, count >= 3 {
                    overlay = DraftPolygon(coordinates: &points, count: count)
                } else if path.kind == .arrow {
                    overlay = ArrowPolyline(coordinates: &points, count: count)
                } else {
                    overlay = DraftPolyline(coordinates: &points, count: count)
                }
                overlayColors[ObjectIdentifier(overlay)] = RGBColor(hex: 0x1976D2)
                map.addOverlay(overlay, level: .aboveLabels)
                draftOverlay = overlay
            }
            for point in path.points {
                let marker = DraftPointAnnotation()
                marker.coordinate = point.clLocation
                draftPoints.append(marker)
            }
            map.addAnnotations(draftPoints)
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
                guard let annotation = view.annotation,
                      let moved = GeoCoordinate(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude) else { break }
                if let section = annotation as? SectionAnnotation {
                    onMoveSection(section.sectionID, moved)
                } else if let label = annotation as? MapObjectAnnotation {
                    onMoveObject(label.objectID, moved)
                } else if let sign = annotation as? TacticalSignAnnotation {
                    onMoveObject(sign.objectID, moved)
                } else if let handle = annotation as? MapResizeHandle {
                    onResizeObject(handle.objectID, moved)
                } else if annotation === marker {
                    onMoveMission(moved)
                }
            case .canceling:
                view.setDragState(.none, animated: true)
            default:
                break
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            onRegionChanging()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionChanging()
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
            if layer.tileTemplate != nil {
                // Mit Speicher: Kacheln bleiben offline verfügbar (Schritt 59).
                let overlay = CachingTileOverlay(layer: layer)
                let cache = TileDiskCache.shared
                Task.detached(priority: .background) { cache.prune() }
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
                // Fahne lässt sich ziehen, solange bearbeitet werden darf.
                if let view = map.view(for: marker) { view.isDraggable = canEdit }
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
            if let drawing = overlay as? DrawingOverlay {
                return DrawingOverlayRenderer(drawing: drawing)
            }
            let color = UIColor(overlayColors[ObjectIdentifier(overlay)] ?? MapObject.defaultColor)
            if let arrow = overlay as? ArrowPolyline {
                let renderer = ArrowRenderer(polyline: arrow)
                renderer.strokeColor = color
                renderer.lineWidth = 5
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = color
                renderer.lineWidth = 3
                renderer.lineDashPattern = [8, 6]
                return renderer
            }
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
                if polygon is DraftPolygon { renderer.lineDashPattern = [8, 6] }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let sign = annotation as? TacticalSignAnnotation {
                let identifier = "sign"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? TacticalSignAnnotationView)
                    ?? TacticalSignAnnotationView(annotation: sign, reuseIdentifier: identifier)
                view.annotation = sign
                view.image = TacticalSignRenderer.image(for: sign.sign, height: 44)
                view.displayPriority = .required
                // Schritte 121/122: gedrückt halten, dann ziehen.
                view.isDraggable = false
                view.allowsMoving = canEdit
                view.onMoved = { [weak self] objectID, coordinate in self?.onMoveObject(objectID, coordinate) }
                view.onTap = { [weak self] objectID in self?.onSelectObject(objectID) }
                view.canShowCallout = false
                view.accessibilityLabel = sign.title
                view.accessibilityHint = canEdit ? "Antippen bearbeitet, gedrückt halten und ziehen verschiebt" : nil
                return view
            }
            if let photo = annotation as? PhotoAnnotation {
                let identifier = "photo"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: photo, reuseIdentifier: identifier)
                view.annotation = photo
                view.markerTintColor = .systemPurple
                view.glyphImage = UIImage(systemName: "camera.fill")
                view.titleVisibility = .hidden
                view.displayPriority = .defaultHigh
                view.clusteringIdentifier = "photo"
                view.accessibilityLabel = photo.title
                return view
            }
            if annotation is DraftPointAnnotation {
                let identifier = "draftPoint"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = MapResizeHandle.image
                view.displayPriority = .required
                view.canShowCallout = false
                return view
            }
            if let label = annotation as? MapObjectAnnotation {
                let identifier = "object"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: label, reuseIdentifier: identifier)
                view.annotation = label
                view.markerTintColor = UIColor(label.color)
                // Schritt 123: Nummer des Suchgebiets in der Markierung, Bezeichnung immer sichtbar.
                if let number = label.number {
                    view.glyphImage = nil
                    view.glyphText = number
                } else {
                    view.glyphText = nil
                    view.glyphImage = UIImage(systemName: "pencil")
                }
                view.titleVisibility = .visible
                // Schritt 132: Beschriftungen weichen einander aus, statt sich zu überdecken;
                // die Nummer in der Markierung bleibt sichtbar.
                view.displayPriority = label.isNamed ? .defaultHigh : .defaultLow
                view.collisionMode = .circle
                // Halten und Ziehen verschiebt die ganze Form (Schritt 60).
                view.isDraggable = canEdit
                return view
            }
            if let handle = annotation as? MapResizeHandle {
                let identifier = "resize"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: handle, reuseIdentifier: identifier)
                view.annotation = handle
                view.image = MapResizeHandle.image
                view.displayPriority = .required
                view.isDraggable = canEdit
                view.canShowCallout = false
                view.accessibilityLabel = "Größe ändern: halten und ziehen"
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
            view.isDraggable = canEdit
            return view
        }
    }
}

extension GeoCoordinate {
    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
