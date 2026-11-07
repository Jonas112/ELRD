import Foundation
import CoreLocation
import ELRDDomain

/// Standortfreigabe „beim Verwenden der App“. Gefragt wird erst, wenn jemand
/// „Mein Standort“ antippt – nicht schon beim Öffnen der Karte.
@MainActor
final class LocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Permission: Equatable { case unknown, allowed, denied }

    @Published private(set) var permission: Permission = .unknown
    /// `true`, solange eine einmalige Ortung läuft („Mein Standort“ als Einsatzort).
    @Published private(set) var isLocating = false
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<GeoCoordinate?, Never>] = []

    /// Frische, genaue Ortung: höchstens 2 Minuten alt und auf 100 m genau.
    nonisolated static func isUsable(_ location: CLLocation, now: Date = Date()) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 100
            && now.timeIntervalSince(location.timestamp) <= 120
    }

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

    /// Einmalige Ortung (Schritt 61): letzte gute Position oder neue Messung;
    /// `nil` ohne Freigabe oder wenn die Ortung scheitert.
    func currentCoordinate() async -> GeoCoordinate? {
        guard permission == .allowed else { return nil }
        if let last = manager.location, Self.isUsable(last) {
            return GeoCoordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard !isLocating else { return }
            isLocating = true
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.requestLocation()
        }
    }

    private func finishLocating(_ coordinate: GeoCoordinate?) {
        isLocating = false
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(returning: coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let best = locations.last.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) } ?? nil
        MainActor.assumeIsolated { self.finishLocating(best) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { self.finishLocating(nil) }
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
