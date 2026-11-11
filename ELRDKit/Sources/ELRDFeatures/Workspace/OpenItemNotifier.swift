import SwiftUI
import UIKit
import AudioToolbox
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
    static let scheduledKinds: Set<OpenItem.Kind> = [.situationReportDue, .longWait, .placeholderOverdue, .arrivalOverdue, .retriageDue]

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
        // Ausgeblendete Arten (Schritt 96) auch nicht vorplanen.
        let hidden = Set(reminders.hiddenOpenItemKinds)
        func shows(_ kind: OpenItem.Kind) -> Bool { !hidden.contains(kind.key) }
        let title = state.mission.isExerciseMission ? "ELRD – ÜBUNG \(state.mission.displayNumber())" : "ELRD – Einsatz \(state.mission.displayNumber())"
        var result: [ScheduledReminder] = []

        if reminders.situationReportMinutes > 0, shows(.situationReportDue) {
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
                && !patient.hasTransportUnit(in: state.units)
                && shows(patient.triage == .sk1 ? .criticalWithoutTransport : patient.triage == .sk2 ? .urgentWithoutTransport : .longWait) {
                let due = patient.metadata.createdAt.addingTimeInterval(Double(reminders.transportWaitMinutes) * 60)
                guard due > now else { continue }
                result.append(ScheduledReminder(
                    id: "\(missionKey).wait.\(patient.id.rawValue.uuidString)", date: due, title: title,
                    body: "Patient \(patient.number) (\(patient.triage.shortName)) wartet seit \(reminders.transportWaitMinutes) min ohne Transportmittel.",
                    target: .patient(patient.id)
                ))
            }
        }
        // Schritt 95: Nachsichtung.
        for patient in state.patients.active where patient.outcome == nil && shows(.retriageDue) {
            let limit = reminders.retriageMinutes(for: patient.triage)
            guard limit > 0, let last = patient.lastTriagedAt else { continue }
            let due = last.addingTimeInterval(Double(limit) * 60)
            guard due > now else { continue }
            result.append(ScheduledReminder(
                id: "\(missionKey).retriage.\(patient.id.rawValue.uuidString)", date: due, title: title,
                body: "Patient \(patient.number) (\(patient.triage.shortName)): Nachsichtung fällig.",
                target: .patient(patient.id)
            ))
        }
        // Schritt 92: zur erwarteten Zeit nachfragen.
        for unit in state.activeUnits where unit.isAwaitingArrival && shows(.arrivalOverdue) {
            guard let due = unit.expectedArrival, due > now else { continue }
            result.append(ScheduledReminder(
                id: "\(missionKey).arrival.\(unit.id.rawValue.uuidString)", date: due, title: title,
                body: "\(unit.displayName) sollte jetzt eintreffen – noch nicht da? Bei der ILS nachfragen.",
                target: .section(.organisation)
            ))
        }
        if reminders.placeholderMinutes > 0, shows(.placeholderOverdue) {
            for unit in state.activeUnits where unit.isPlaceholder && !unit.isAwaitingArrival {
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

/// Eintrag unter „Benachrichtigungen“ (Glocke): ein neuer offener Punkt (Schritt 105).
/// Nur auf diesem Gerät – jedes Gerät erkennt neue Punkte selbst.
struct OpenItemRecord: Identifiable, Equatable {
    let id: UUID
    let missionID: MissionID
    let item: OpenItem
    let date: Date
    var isRead: Bool
}

/// Meldet neue offene Punkte (Schritt 83, 105): als lokale Mitteilung mit Ton –
/// auch wenn die App offen ist – und als Eintrag unter „Benachrichtigungen“. Ohne
/// Erlaubnis für Mitteilungen: Hinweis oben in der App mit Ton. Zeitabhängige
/// Erinnerungen werden vorgeplant.
@MainActor
@Observable
final class OpenItemNotifier {
    /// Zuletzt neu hinzugekommener Punkt (Hinweis in der App, wenn Mitteilungen aus sind).
    private(set) var banner: OpenItem?
    /// Neue offene Punkte, neueste zuletzt (je Einsatz höchstens 100).
    private(set) var records: [OpenItemRecord] = []

    @ObservationIgnored private var known: [MissionID: Set<String>] = [:]
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastScheduled: [MissionID: [ScheduledReminder]] = [:]
    @ObservationIgnored private let enabled: Bool
    /// Mitteilungen erlaubt (sonst Hinweis in der App).
    @ObservationIgnored private var isAuthorized = false

    /// `enabled == false` bei Beispieldaten: keine Mitteilungen, kein Nachfragen.
    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Fragt beim ersten Mal nach der Erlaubnis; danach liefert iOS nur den Stand.
    func requestAuthorizationIfNeeded() {
        guard enabled else { return }
        Task { @MainActor [weak self] in
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            self?.isAuthorized = granted
        }
    }

    /// Einträge eines Einsatzes, neueste zuerst.
    func records(for mission: MissionID) -> [OpenItemRecord] {
        records.filter { $0.missionID == mission }.reversed()
    }

    func unreadCount(for mission: MissionID) -> Int {
        records.filter { $0.missionID == mission && !$0.isRead }.count
    }

    func markAllRead(_ mission: MissionID) {
        guard records.contains(where: { $0.missionID == mission && !$0.isRead }) else { return }
        for index in records.indices where records[index].missionID == mission {
            records[index].isRead = true
        }
    }

    private func record(_ items: [OpenItem], mission: MissionID, now: Date, isRead: Bool) {
        guard !items.isEmpty else { return }
        records += items.sorted { $0.kind < $1.kind }.map {
            OpenItemRecord(id: UUID(), missionID: mission, item: $0, date: now, isRead: isRead)
        }
        let own = records.filter { $0.missionID == mission }
        if own.count > 100 {
            let drop = Set(own.prefix(own.count - 100).map(\.id))
            records.removeAll { drop.contains($0.id) }
        }
    }

    /// Nach jeder Änderung und im Minutentakt: neue Punkte melden, Erinnerungen planen.
    func evaluate(_ state: MissionState, now: Date, settings: AppSettings, appIsActive: Bool) {
        let reminders = settings.reminders
        let items = OpenItem.items(for: state, now: now, reminders: reminders)
        let mission = state.mission.id
        let fresh = OpenItemAlerts.newItems(previous: known[mission], current: items)
        known[mission] = Set(items.map(\.id))

        if let first = fresh.sorted(by: { $0.kind < $1.kind }).first {
            record(fresh, mission: mission, now: now, isRead: false)
            if enabled, isAuthorized, reminders.notifiesWhenLocked {
                // Mitteilung mit Ton, auch im Vordergrund. Zeitabhängige Punkte sind
                // schon vorgeplant – nicht doppelt melden.
                let untimed = fresh.filter { !OpenItemAlerts.scheduledKinds.contains($0.kind) }
                if !untimed.isEmpty { post(untimed, state: state) }
            } else if appIsActive {
                show(first)
            }
        }
        if enabled { schedule(state, now: now, reminders: reminders) }
    }

    /// Eigene Änderung auf diesem Gerät: Stand übernehmen, ohne Hinweis – wer den
    /// Patienten gerade selbst angelegt hat, braucht keinen Hinweis darauf.
    func acknowledge(_ state: MissionState, now: Date, settings: AppSettings) {
        let items = OpenItem.items(for: state, now: now, reminders: settings.reminders)
        // In der Liste festhalten, aber ohne Ton und als gelesen.
        let fresh = OpenItemAlerts.newItems(previous: known[state.mission.id], current: items)
        record(fresh, mission: state.mission.id, now: now, isRead: true)
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
        markAllRead(mission)
        guard enabled, let planned = lastScheduled.removeValue(forKey: mission), !planned.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: planned.map(\.id))
    }

    private func show(_ item: OpenItem) {
        bannerTask?.cancel()
        withAnimation(.snappy) { banner = item }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        // Ton auch ohne Mitteilungs-Erlaubnis (Schritt 105).
        AudioServicesPlaySystemSound(1007)
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
        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(radius: 8, y: 4)
        .padding(.horizontal, Spacing.l)
        .frame(maxWidth: 720)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
