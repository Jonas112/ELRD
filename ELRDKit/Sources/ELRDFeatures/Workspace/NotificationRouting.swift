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

/// Schritt 151: angetippte Mitteilung zu einem Einsatz aus Alamos FE2.
public struct AlarmNotificationRoute: Equatable, Sendable {
    /// Kennung im ELRD-Backend (`AlamosAlarm.id`).
    public let alarmID: UUID
    /// FE2-Einsatznummer – damit der übernommene ELRD-Einsatz auch ohne Abruf gefunden wird.
    public let externalID: String?
}

/// Zusatzdaten der FE2-Mitteilungen – gleich bei Push vom Backend und eigenen Mitteilungen.
enum AlamosNotificationPayload {
    static func userInfo(for alarm: AlamosAlarm) -> [String: Any] {
        ["elrd": ["kind": "alamos", "alarmId": alarm.id.uuidString.lowercased(), "externalId": alarm.externalId]]
    }

    static func route(from userInfo: [AnyHashable: Any]) -> AlarmNotificationRoute? {
        guard let elrd = userInfo["elrd"] as? [String: Any], elrd["kind"] as? String == "alamos",
              let text = elrd["alarmId"] as? String, let id = UUID(uuidString: text) else { return nil }
        let external = (elrd["externalId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AlarmNotificationRoute(alarmID: id, externalID: external)
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

    // MARK: Alamos FE2 (Schritt 151)

    /// Angetippte FE2-Mitteilung, bis Einsatzliste oder Einsatz sie übernimmt.
    public private(set) var pendingAlarm: AlarmNotificationRoute?
    /// Übernommener Einsatz, in dem die Änderungsliste aufgehen soll.
    public private(set) var alarmReview: MissionID?

    func receive(_ route: AlarmNotificationRoute) {
        pendingAlarm = route
    }

    func discardAlarm() {
        pendingAlarm = nil
    }

    /// Mitteilung gehört zu einem übernommenen Einsatz: dort die Änderungen zeigen.
    func routeAlarmToMission(_ mission: MissionID) {
        pendingAlarm = nil
        alarmReview = mission
    }

    func takeAlarmReview(for mission: MissionID) -> Bool {
        guard alarmReview == mission else { return false }
        alarmReview = nil
        return true
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
        let userInfo = response.notification.request.content.userInfo
        let route = NotificationPayload.route(from: userInfo)
        let alarmRoute = AlamosNotificationPayload.route(from: userInfo)
        completionHandler()
        if let route {
            Task { @MainActor in NotificationInbox.shared.receive(route) }
        } else if let alarmRoute {
            Task { @MainActor in NotificationInbox.shared.receive(alarmRoute) }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Schritt 144: Push vom ELRD-Backend – Abruf anstoßen, jeden Einsatz nur einmal melden.
        if notification.request.trigger is UNPushNotificationTrigger {
            let userInfo = notification.request.content.userInfo
            let elrd = userInfo["elrd"] as? [String: Any]
            let kind = elrd?["kind"] as? String
            let alarmID = elrd?["alarmId"] as? String
            let options = await MainActor.run {
                AlamosAnnouncements.presentation(for: ["elrd": ["kind": kind ?? "", "alarmId": alarmID ?? ""]])
            }
            if let options { return options }
        }
        // Schritt 105: neue offene Punkte auch bei offener App mit Banner und Ton.
        return [.banner, .list, .sound]
    }
}
