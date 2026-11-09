import Foundation
import Observation
import UserNotifications
import ELRDDomain

/// Wohin eine angetippte Mitteilung führt (Schritt 84).
public struct NotificationRoute: Equatable, Sendable {
    public let missionID: MissionID
    public let target: OpenItem.Target?
}

/// Ziel als Text in den Zusatzdaten einer Mitteilung – ohne Namen, nur Kennungen.
enum NotificationPayload {
    static let missionKey = "elrd.mission"
    static let targetKey = "elrd.target"

    static func userInfo(mission: MissionID, target: OpenItem.Target?) -> [String: String] {
        var info = [missionKey: mission.rawValue.uuidString]
        if let target { info[targetKey] = encode(target) }
        return info
    }

    static func route(from userInfo: [AnyHashable: Any]) -> NotificationRoute? {
        guard let text = userInfo[missionKey] as? String, let uuid = UUID(uuidString: text) else { return nil }
        let target = (userInfo[targetKey] as? String).flatMap(decode)
        return NotificationRoute(missionID: MissionID(uuid), target: target)
    }

    static func encode(_ target: OpenItem.Target) -> String {
        switch target {
        case .section(let section): "section:\(section.rawValue)"
        case .patient(let id): "patient:\(id.rawValue.uuidString)"
        case .messages: "messages"
        case .situationReport: "situationReport"
        case .hospitals: "hospitals"
        }
    }

    static func decode(_ text: String) -> OpenItem.Target? {
        switch text {
        case "messages": return .messages
        case "situationReport": return .situationReport
        case "hospitals": return .hospitals
        default: break
        }
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "patient": return UUID(uuidString: parts[1]).map { .patient(PatientID($0)) }
        case "section": return WorkspaceSection(rawValue: parts[1]).map { .section($0) }
        default: return nil
        }
    }
}

/// Angetippte Mitteilung, bis der passende Einsatz offen ist und sie übernimmt.
@MainActor
@Observable
public final class NotificationInbox {
    public static let shared = NotificationInbox()
    public private(set) var pending: NotificationRoute?

    private init() {}

    func receive(_ route: NotificationRoute) {
        pending = route
    }

    /// Ziel für diesen Einsatz übernehmen (einmalig).
    func take(for mission: MissionID) -> NotificationRoute? {
        guard let pending, pending.missionID == mission else { return nil }
        self.pending = nil
        return pending
    }

    func discard() {
        pending = nil
    }
}

/// Nimmt angetippte Mitteilungen entgegen und zeigt sie auch bei offener App
/// (Banner, Mitteilungszentrale, Ton – Schritt 105).
public final class ELRDNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = ELRDNotificationDelegate()

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = NotificationPayload.route(from: response.notification.request.content.userInfo)
        completionHandler()
        guard let route else { return }
        Task { @MainActor in NotificationInbox.shared.receive(route) }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Schritt 105: neue offene Punkte auch bei offener App mit Banner und Ton.
        completionHandler([.banner, .list, .sound])
    }
}
