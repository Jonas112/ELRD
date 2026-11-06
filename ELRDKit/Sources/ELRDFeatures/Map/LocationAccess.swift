import Foundation
import CoreLocation

/// Standortfreigabe „beim Verwenden der App“. Gefragt wird erst, wenn jemand
/// „Mein Standort“ antippt – nicht schon beim Öffnen der Karte.
@MainActor
final class LocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Permission: Equatable { case unknown, allowed, denied }

    @Published private(set) var permission: Permission = .unknown
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        permission = Self.permission(for: manager.authorizationStatus)
    }

    var isAllowed: Bool { permission == .allowed }

    /// Fragt einmalig nach; danach entscheidet der Benutzer in den Einstellungen.
    func request() {
        guard permission == .unknown else { return }
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.permission = Self.permission(for: status)
        }
    }

    nonisolated static func permission(for status: CLAuthorizationStatus) -> Permission {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        case .denied, .restricted: .denied
        default: .unknown
        }
    }
}
