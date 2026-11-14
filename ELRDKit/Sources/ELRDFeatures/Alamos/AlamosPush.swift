import Foundation
import Observation
import UserNotifications

/// Gerätekennzeichen für Push-Mitteilungen (Schritt 144), kommt über den App-Delegate.
///
/// Dasselbe Kennzeichen nutzt iCloud für stille Mitteilungen; das ELRD-Backend schickt
/// damit sichtbare Mitteilungen bei neuen Einsätzen aus Alamos FE2.
@MainActor
@Observable
public final class PushToken {
    public static let shared = PushToken()

    /// Hexadezimal, wie Apple es erwartet.
    public private(set) var hex: String?
    public private(set) var errorMessage: String?
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    public func receive(_ data: Data) {
        let value = data.map { String(format: "%02x", $0) }.joined()
        errorMessage = nil
        guard value != hex else { return }
        hex = value
        onChange?()
    }

    public func fail(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    /// Aus Xcode installiert: Entwicklungsumgebung von Apple; TestFlight/App Store: Produktion.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

/// Ein Einsatz soll nur einmal melden – ob die Push-Mitteilung des Backends oder der
/// eigene Abruf zuerst da ist (Schritt 144).
@MainActor
enum AlamosAnnouncements {
    private static var announced: Set<String> = []
    /// Abruf sofort anstoßen, wenn eine Push-Mitteilung ankommt.
    static var onPush: (@MainActor () -> Void)?

    static func identifier(for id: UUID) -> String {
        "alamos-\(id.uuidString.lowercased())"
    }

    /// `true` beim ersten Mal (und merkt sich den Einsatz).
    static func claim(_ identifier: String) -> Bool {
        announced.insert(identifier).inserted
    }

    /// Push-Mitteilung bei offener App: Abruf anstoßen, Banner nur, wenn noch nicht gemeldet.
    static func presentation(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions? {
        guard let elrd = userInfo["elrd"] as? [String: Any], let kind = elrd["kind"] as? String else { return nil }
        if kind == "test" { return [.banner, .list, .sound] }
        guard kind == "alamos" else { return nil }
        onPush?()
        guard let text = elrd["alarmId"] as? String, let id = UUID(uuidString: text) else { return [.banner, .list, .sound] }
        return claim(identifier(for: id)) ? [.banner, .list, .sound] : [.list]
    }
}
