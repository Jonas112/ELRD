import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDStore

@Suite("Hinweise bei offenen Punkten (Schritt 83)")
@MainActor
struct OpenItemAlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyItemsAddedLaterAreNew() throws {
        let store = try PreviewData.makeStore(now: now)
        let first = OpenItem.items(for: store.state, now: now)
        #expect(OpenItemAlerts.newItems(previous: nil, current: first).isEmpty, "Öffnen des Einsatzes meldet nichts")

        let known = Set(first.map(\.id))
        #expect(OpenItemAlerts.newItems(previous: known, current: first).isEmpty)

        let patient = try store.perform(AddPatient(triage: .sk1))
        let fresh = OpenItemAlerts.newItems(previous: known, current: OpenItem.items(for: store.state, now: now))
        #expect(fresh.map(\.kind) == [.criticalWithoutTransport])
        #expect(fresh.first?.target == .patient(patient.id))
    }

    @Test func timeBasedRemindersArePlannedAhead() throws {
        let store = try PreviewData.makeStore(now: now)
        let planned = OpenItemAlerts.upcoming(for: store.state, now: now, reminders: ReminderSettings())
        // Lagemeldung + 6 Patienten SK 1–3 ohne Transportmittel + 3 Platzhalter (RD 3).
        #expect(planned.count == 10)
        #expect(planned.map(\.date) == planned.map(\.date).sorted(), "nächste zuerst")
        #expect(planned.first?.date == now.addingTimeInterval(15 * 60), "Platzhalter nach 15 min")
        #expect(planned.contains { $0.date == now.addingTimeInterval(30 * 60) && $0.body.contains("Lagemeldung") })
        #expect(Set(planned.map(\.id)).count == planned.count, "eindeutige Kennungen")

        // Eine Stunde später ist nichts mehr „künftig“ – das zeigt dann die Lage.
        #expect(OpenItemAlerts.upcoming(for: store.state, now: now.addingTimeInterval(3600), reminders: ReminderSettings()).isEmpty)

        var off = ReminderSettings()
        off.situationReportMinutes = 0
        off.transportWaitMinutes = 0
        off.placeholderMinutes = 0
        #expect(OpenItemAlerts.upcoming(for: store.state, now: now, reminders: off).isEmpty, "„Aus“ plant nichts")
    }

    @Test func lockScreenTextHasNoPatientName() throws {
        let store = try PreviewData.makeStore(now: now)
        let patient = store.state.activePatients[0]
        try store.perform(EditPatient(patientID: patient.id) {
            $0.firstName = "Erika"
            $0.lastName = "Mustermann"
        })
        let item = try #require(OpenItem.items(for: store.state, now: now).first { $0.target == .patient(patient.id) })
        #expect(item.title.contains("Mustermann"), "in der App mit Namen")
        let body = OpenItemAlerts.body(for: item, state: store.state)
        #expect(!body.contains("Mustermann"))
        #expect(body.contains("SK 1"))
        let planned = OpenItemAlerts.upcoming(for: store.state, now: now, reminders: ReminderSettings())
        #expect(!planned.contains { $0.body.contains("Mustermann") || $0.body.contains("Erika") })
    }

    @Test func reminderSettingsDecodeWithoutNewField() throws {
        let old = Data(#"{"situationReportMinutes":20,"transportWaitMinutes":10,"placeholderMinutes":5}"#.utf8)
        let decoded = try JSONDecoder().decode(ReminderSettings.self, from: old)
        #expect(decoded.notifiesWhenLocked, "bisherige Einstellungen: Mitteilungen an")
        #expect(decoded.situationReportMinutes == 20)
    }

    @Test func leadershipPersonFitsRole() {
        let lna = LeadershipPerson(name: "Dr. Weber", roles: [.lna])
        #expect(lna.fits(.lna))
        #expect(!lna.fits(.orgl))
        let anyRole = LeadershipPerson(name: "Meier")
        #expect(anyRole.fits(.orgl), "ohne Funktion: überall wählbar")
        #expect(anyRole.fits(nil))
    }

    // MARK: 84 Mitteilung antippen

    @Test func notificationPayloadRoundTrips() throws {
        let mission = MissionID()
        let patient = PatientID()
        let targets: [OpenItem.Target] = [.patient(patient), .section(.organisation), .messages, .situationReport, .hospitals]
        for target in targets {
            let info = NotificationPayload.userInfo(mission: mission, target: target)
            let route = try #require(NotificationPayload.route(from: info))
            #expect(route == NotificationRoute(missionID: mission, target: target))
        }
        #expect(NotificationPayload.route(from: NotificationPayload.userInfo(mission: mission, target: nil))?.target == nil)
        #expect(NotificationPayload.route(from: ["x": "y"]) == nil)
        #expect(NotificationPayload.decode("patient:kaputt") == nil)
    }

    @Test func plannedRemindersLeadToTheirItem() throws {
        let store = try PreviewData.makeStore(now: now)
        let planned = OpenItemAlerts.upcoming(for: store.state, now: now, reminders: ReminderSettings())
        #expect(planned.contains { $0.target == .situationReport })
        #expect(planned.contains { $0.target == .patient(store.state.activePatients[0].id) })
        #expect(planned.contains { $0.target == .section(.organisation) })
    }

    @Test func inboxHandsRouteOnlyToItsMission() {
        let inbox = NotificationInbox.shared
        let mission = MissionID()
        inbox.receive(NotificationRoute(missionID: mission, target: .messages))
        #expect(inbox.take(for: MissionID()) == nil, "anderer Einsatz übernimmt nicht")
        #expect(inbox.take(for: mission)?.target == .messages)
        #expect(inbox.pending == nil)
    }

    // MARK: 90 Live Activity

    @Test func liveActivityContentHasCountsWithoutNames() throws {
        let store = try PreviewData.makeStore(now: now)
        let content = LiveActivityController.content(for: store.state, settings: AppSettings(), now: now)
        #expect(content.sk1 == 1)
        #expect(content.sk2 == 2)
        #expect(content.sk3 == 3)
        #expect(content.untriaged == 1)
        #expect(content.waiting == 7)
        #expect(content.nextReportAt == store.state.mission.startedAt.addingTimeInterval(30 * 60))
        var off = AppSettings()
        off.reminders.situationReportMinutes = 0
        #expect(LiveActivityController.content(for: store.state, settings: off, now: now).nextReportAt == nil)
    }
}
