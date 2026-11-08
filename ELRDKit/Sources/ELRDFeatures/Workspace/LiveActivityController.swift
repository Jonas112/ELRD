@preconcurrency import ActivityKit
import Foundation
import Observation
import ELRDDomain
import ELRDStore
import ELRDLiveActivity

/// Startet, aktualisiert und beendet die Live Activity des geöffneten Einsatzes
/// (Schritt 90). Nur lokal (E105); ohne Erlaubnis oder in der Demo passiert nichts.
@MainActor
@Observable
final class LiveActivityController {
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private var activity: Activity<MissionActivityAttributes>?
    @ObservationIgnored private var lastContent: MissionActivityAttributes.ContentState?
    @ObservationIgnored private var cleanedUp = false

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Nach jeder Änderung und im Minutentakt.
    func update(_ state: MissionState, settings: AppSettings, now: Date) {
        guard enabled else { return }
        cleanUpOnce(keeping: state.mission.id)
        guard settings.showsLiveActivity, !state.mission.isClosed,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            end()
            return
        }
        let content = Self.content(for: state, settings: settings, now: now)
        let missionKey = state.mission.id.rawValue.uuidString
        if let activity, activity.attributes.missionID == missionKey {
            guard content != lastContent else { return }
            lastContent = content
            Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
            return
        }
        end()
        if let running = Activity<MissionActivityAttributes>.activities.first(where: { $0.attributes.missionID == missionKey }) {
            activity = running
            lastContent = content
            Task { await running.update(ActivityContent(state: content, staleDate: nil)) }
            return
        }
        let attributes = MissionActivityAttributes(
            missionID: missionKey,
            missionNumber: state.mission.displayNumber(),
            title: state.mission.title,
            startedAt: state.mission.startedAt,
            isExercise: state.mission.isExerciseMission
        )
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: content, staleDate: nil), pushType: nil)
        lastContent = content
    }

    /// Einsatz verlassen oder beendet.
    func end() {
        guard let activity else { return }
        self.activity = nil
        lastContent = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Reste aus einem früheren Start (anderer Einsatz) beenden.
    private func cleanUpOnce(keeping mission: MissionID) {
        guard !cleanedUp else { return }
        cleanedUp = true
        let key = mission.rawValue.uuidString
        for stale in Activity<MissionActivityAttributes>.activities where stale.attributes.missionID != key {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Inhalt ohne Namen: Zähler, wartende Patienten, offene Punkte, nächste Lagemeldung.
    static func content(for state: MissionState, settings: AppSettings, now: Date) -> MissionActivityAttributes.ContentState {
        let patients = state.patients.active
        let counts = Patient.countsByTriage(patients)
        let minutes = settings.reminders.situationReportMinutes
        let last = state.lastSituationReportAt ?? state.mission.startedAt
        let open = OpenItem.items(for: state, now: now, reminders: settings.reminders).filter { $0.kind != .unreadMessages }
        return MissionActivityAttributes.ContentState(
            sk1: counts[.sk1] ?? 0,
            sk2: counts[.sk2] ?? 0,
            sk3: counts[.sk3] ?? 0,
            untriaged: counts[.ungesichtet] ?? 0,
            waiting: patients.filter { $0.status == .waiting && $0.outcome == nil && $0.triage != .verstorben && $0.triage != .unverletzt }.count,
            openItems: open.count,
            nextReportAt: minutes > 0 ? last.addingTimeInterval(Double(minutes) * 60) : nil
        )
    }
}
