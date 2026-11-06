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
    /// Kartenmitte nach jeder Bewegung (zum Setzen des Einsatzorts).
    var onCenterChange: (GeoCoordinate) -> Void = { _ in }

    /// Ausschnitt um den Einsatzort (ca. 800 m), sonst ganz Deutschland.
    static func initialRegion(around coordinate: GeoCoordinate?) -> MKCoordinateRegion {
        if let coordinate {
            return MKCoordinateRegion(center: coordinate.clLocation, latitudinalMeters: 800, longitudinalMeters: 800)
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

        context.coordinator.onCenterChange = onCenterChange
        map.setRegion(Self.initialRegion(around: missionCoordinate), animated: false)
        context.coordinator.apply(layer: layer, to: map)
        context.coordinator.updateMissionMarker(missionCoordinate, title: missionTitle, on: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCenterChange = onCenterChange
        coordinator.apply(layer: layer, to: map)
        coordinator.updateMissionMarker(missionCoordinate, title: missionTitle, on: map)
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
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
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
