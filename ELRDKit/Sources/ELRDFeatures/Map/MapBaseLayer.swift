import Foundation

/// Kartengrundlage (wie ELRDRG `MapProviderType`): Apple-Karten oder Kacheln von
/// OpenStreetMap bzw. OpenTopoMap. Die Wahl gilt je Gerät.
public enum MapBaseLayer: String, CaseIterable, Identifiable, Sendable {
    case apple, satellite, hybrid, openStreetMap, openTopoMap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apple: "Karte (Apple)"
        case .satellite: "Satellit"
        case .hybrid: "Hybrid"
        case .openStreetMap: "OpenStreetMap"
        case .openTopoMap: "Topografisch (OpenTopoMap)"
        }
    }

    /// Kurz für die Schaltfläche.
    public var shortTitle: String {
        switch self {
        case .apple: "Karte"
        case .satellite: "Satellit"
        case .hybrid: "Hybrid"
        case .openStreetMap: "OSM"
        case .openTopoMap: "Topo"
        }
    }

    public var systemImage: String {
        switch self {
        case .apple: "map"
        case .satellite: "globe.europe.africa.fill"
        case .hybrid: "square.2.layers.3d"
        case .openStreetMap: "map.fill"
        case .openTopoMap: "mountain.2"
        }
    }

    /// Adressvorlage der Kacheln (`{z}/{x}/{y}`); `nil` bei Apple-Karten.
    public var tileTemplate: String? {
        switch self {
        case .apple, .satellite, .hybrid: nil
        case .openStreetMap: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .openTopoMap: "https://tile.opentopomap.org/{z}/{x}/{y}.png"
        }
    }

    /// Größte Zoomstufe, die der Kachelserver liefert.
    public var maximumZoom: Int {
        switch self {
        case .openTopoMap: 17
        default: 19
        }
    }

    /// Pflichtangabe der Lizenz (OSM: ODbL, OpenTopoMap: CC-BY-SA); `nil` bei Apple.
    public var attribution: String? {
        switch self {
        case .apple, .satellite, .hybrid: nil
        case .openStreetMap: "© OpenStreetMap-Mitwirkende"
        case .openTopoMap: "Kartendaten © OpenStreetMap-Mitwirkende, SRTM · Darstellung © OpenTopoMap (CC-BY-SA)"
        }
    }

    public static let storageKey = "mapBaseLayer"
}
