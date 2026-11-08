import SwiftUI
import UIKit
import UserNotifications
import ELRDDomain
import ELRDStore

// MARK: - Logik (ohne Oberfläche testbar)

/// Künftige Erinnerung, die als lokale Mitteilung vorgeplant wird – damit sie auch
/// bei gesperrtem Gerät erscheint, wenn die App nicht läuft.
struct ScheduledReminder: Equatable {
    let id: String
    let date: Date
    let title: String
    let body: String
    /// Wohin das Antippen führt (Schritt 84).
    var target: OpenItem.Target? = nil
}

enum OpenItemAlerts {
    /// Arten, die als zeitabhängige Erinnerung vorgeplant werden.
    static let scheduledKinds: Set<OpenItem.Kind> = [.situationReportDue, .longWait, .placeholderOverdue]

    /// Offene Punkte, die seit dem letzten Stand neu sind. Beim ersten Stand eines
    /// Einsatzes (`previous == nil`) ist nichts „neu“ – sonst meldet das Öffnen alles.
    static func newItems(previous: Set<String>?, current: [OpenItem]) -> [OpenItem] {
        guard let previous else { return [] }
        return current.filter { !previous.contains($0.id) && $0.kind != .unreadMessages }
    }

    /// Zeitabhängige Erinnerungen, die künftig fällig werden. Texte ohne Namen –
    /// sie stehen auf dem Sperrbildschirm.
    static func upcoming(for state: MissionState, now: Date, reminders: ReminderSettings) -> [ScheduledReminder] {
        guard !state.mission.isClosed else { return [] }
        let missionKey = state.mission.id.rawValue.uuidString
        let title = state.mission.isExerciseMission ? "ELRD – ÜBUNG \(state.mission.displayNumber())" : "ELRD – Einsatz \(state.mission.displayNumber())"
        var result: [ScheduledReminder] = []

        if reminders.situationReportMinutes > 0 {
            let last = state.lastSituationReportAt ?? state.mission.startedAt
            let due = last.addingTimeInterval(Double(reminders.situationReportMinutes) * 60)
            if due > now {
                result.append(ScheduledReminder(id: "\(missionKey).situationReport", date: due, title: title,
                                                body: "Lagemeldung an die ILS fällig.", target: .situationReport))
            }
        }
        if reminders.transportWaitMinutes > 0 {
            for patient in state.patients.active where patient.outcome == nil
                && [.sk1, .sk2, .sk3].contains(patient.triage)
                && !patient.hasTransportUnit(in: state.units) {
                let due = patient.metadata.createdAt.addingTimeInterval(Double(reminders.transportWaitMinutes) * 60)
                guard due > now else { continue }
                result.append(ScheduledReminder(
                    id: "\(missionKey).wait.\(patient.id.rawValue.uuidString)", date: due, title: title,
                    body: "Patient \(patient.number) (\(patient.triage.shortName)) wartet seit \(reminders.transportWaitMinutes) min ohne Transportmittel.",
                    target: .patient(patient.id)
                ))
            }
        }
        if reminders.placeholderMinutes > 0 {
            for unit in state.activeUnits where unit.isPlaceholder {
                let due = unit.metadata.createdAt.addingTimeInterval(Double(reminders.placeholderMinutes) * 60)
                guard due > now else { continue }
                result.append(ScheduledReminder(
                    id: "\(missionKey).placeholder.\(unit.id.rawValue.uuidString)", date: due, title: title,
                    body: "\(unit.type.shortName) seit \(reminders.placeholderMinutes) min angefordert, noch ohne Fahrzeug – bei der ILS nachfragen.",
                    target: .section(.organisation)
                ))
            }
        }
        // iOS hält höchstens 64 geplante Mitteilungen je App – die nächsten zuerst.
        return Array(result.sorted { $0.date < $1.date }.prefix(40))
    }

    /// Text eines neuen offenen Punkts für eine Mitteilung (ohne Namen).
    static func body(for item: OpenItem, state: MissionState) -> String {
        if case .patient(let id) = item.target, let patient = state.patients.first(where: { $0.id == id }) {
            let problem = item.title.replacingOccurrences(of: patient.displayName, with: "").trimmingCharacters(in: .whitespaces)
            return "Patient \(patient.number) (\(patient.triage.shortName)) \(problem)"
        }
        return item.title
    }
}

// MARK: - Hinweise in der App und Mitteilungen

/// Meldet neue offene Punkte: als Hinweis oben in der App und – wenn die App im
/// Hintergrund ist oder das Gerät gesperrt – als lokale Mitteilung. Zeitabhängige
/// Erinnerungen werden zusätzlich vorgeplant.
@MainActor
@Observable
final class OpenItemNotifier {
    /// Zuletzt neu hinzugekommener Punkt (Hinweis in der App).
    private(set) var banner: OpenItem?

    @ObservationIgnored private var known: [MissionID: Set<String>] = [:]
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastScheduled: [MissionID: [ScheduledReminder]] = [:]
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private var authorizationRequested = false

    /// `enabled == false` bei Beispieldaten: keine Mitteilungen, kein Nachfragen.
    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Einmal fragen, ob Mitteilungen erlaubt sind (beim ersten geöffneten Einsatz).
    func requestAuthorizationIfNeeded() {
        guard enabled, !authorizationRequested else { return }
        authorizationRequested = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// Nach jeder Änderung und im Minutentakt: neue Punkte melden, Erinnerungen planen.
    func evaluate(_ state: MissionState, now: Date, settings: AppSettings, appIsActive: Bool) {
        let reminders = settings.reminders
        let items = OpenItem.items(for: state, now: now, reminders: reminders)
        let mission = state.mission.id
        let fresh = OpenItemAlerts.newItems(previous: known[mission], current: items)
        known[mission] = Set(items.map(\.id))

        if let first = fresh.sorted(by: { $0.kind < $1.kind }).first {
            if appIsActive {
                show(first)
            } else if enabled, reminders.notifiesWhenLocked {
                // Zeitabhängige Punkte sind schon vorgeplant – nicht doppelt melden.
                let untimed = fresh.filter { !OpenItemAlerts.scheduledKinds.contains($0.kind) }
                if !untimed.isEmpty { post(untimed, state: state) }
            }
        }
        if enabled { schedule(state, now: now, reminders: reminders) }
    }

    /// Eigene Änderung auf diesem Gerät: Stand übernehmen, ohne Hinweis – wer den
    /// Patienten gerade selbst angelegt hat, braucht keinen Hinweis darauf.
    func acknowledge(_ state: MissionState, now: Date, settings: AppSettings) {
        let items = OpenItem.items(for: state, now: now, reminders: settings.reminders)
        known[state.mission.id] = Set(items.map(\.id))
        if enabled { schedule(state, now: now, reminders: settings.reminders) }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        withAnimation { banner = nil }
    }

    /// Einsatz verlassen: geplante Erinnerungen dieses Einsatzes entfernen.
    func forget(_ mission: MissionID) {
        known[mission] = nil
        guard enabled, let planned = lastScheduled.removeValue(forKey: mission), !planned.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: planned.map(\.id))
    }

    private func show(_ item: OpenItem) {
        bannerTask?.cancel()
        withAnimation(.snappy) { banner = item }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation { self?.banner = nil }
        }
    }

    private func post(_ items: [OpenItem], state: MissionState) {
        let center = UNUserNotificationCenter.current()
        for item in items.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = state.mission.isExerciseMission ? "ELRD – ÜBUNG – neuer offener Punkt" : "ELRD – neuer offener Punkt"
            content.body = OpenItemAlerts.body(for: item, state: state)
            content.sound = .default
            content.threadIdentifier = state.mission.id.rawValue.uuidString
            content.userInfo = NotificationPayload.userInfo(mission: state.mission.id, target: item.target)
            let request = UNNotificationRequest(identifier: "\(state.mission.id.rawValue.uuidString).new.\(item.id)", content: content, trigger: nil)
            center.add(request)
        }
    }

    private func schedule(_ state: MissionState, now: Date, reminders: ReminderSettings) {
        let mission = state.mission.id
        let planned = reminders.notifiesWhenLocked ? OpenItemAlerts.upcoming(for: state, now: now, reminders: reminders) : []
        let previous = lastScheduled[mission] ?? []
        guard planned != previous else { return }
        let center = UNUserNotificationCenter.current()
        let stale = Set(previous.map(\.id)).subtracting(planned.map(\.id))
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
        for reminder in planned where !previous.contains(reminder) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = mission.rawValue.uuidString
            content.userInfo = NotificationPayload.userInfo(mission: mission, target: reminder.target)
            let interval = max(1, reminder.date.timeIntervalSince(now))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
        lastScheduled[mission] = planned
    }
}

/// Hinweis oben im Arbeitsbereich: neuer offener Punkt, antippen führt hin.
struct OpenItemBanner: View {
    let item: OpenItem
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "bell.badge.fill")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Neuer offener Punkt").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                Text(item.title).font(.headline).foregroundStyle(.white).lineLimit(2)
            }
            Spacer(minLength: Spacing.s)
            Button(item.actionTitle, action: onOpen)
                .font(.headline)
                .buttonStyle(.bordered)
                .tint(.white)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
            }
            .accessibilityLabel("Hinweis schließen")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 8, y: 4)
        .padding(.horizontal, Spacing.l)
        .frame(maxWidth: 720)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
