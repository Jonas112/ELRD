import Foundation
import Testing
@testable import ELRDFeatures
@testable import ELRDDomain
import ELRDAuth
import ELRDStore

/// Schritt 140: Eingang für Einsätze aus Alamos FE2 und Übernahme-Formular.
@MainActor
struct AlamosInboxTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_792_000_000)
    }

    func makeInbox(clock: Clock = Clock()) throws -> AlamosInbox {
        let settings = AppSettingsStore(repository: nil)
        try settings.update { $0.alamos.isEnabled = true }
        return AlamosInbox(settings: settings, secureStore: InMemorySecureStore(), now: { clock.now })
    }

    func alarm(_ id: UUID = UUID(), revision: Int = 1, minutesAgo: Double = 1, closed: Bool = false, test: Bool = false, now: Date) -> AlamosAlarm {
        AlamosAlarm(
            id: id,
            externalId: id.uuidString.prefix(6).description,
            revision: revision,
            receivedAt: now.addingTimeInterval(-minutesAgo * 60),
            closedAt: closed ? now : nil,
            isTest: test,
            data: AlamosAlarmData(keyword: "RD 2")
        )
    }

    @Test func firstLoadMarksOnlyRecentAsNewWithoutNotifying() throws {
        let clock = Clock()
        let inbox = try makeInbox(clock: clock)
        var notified: [AlamosAlarm] = []
        inbox.onNewAlarm = { notified.append($0) }
        let recent = alarm(minutesAgo: 2, now: clock.now)
        let old = alarm(minutesAgo: 120, now: clock.now)
        inbox.apply([old, recent])
        #expect(inbox.alarms.map(\.id) == [recent.id, old.id], "neueste Änderung zuerst")
        #expect(inbox.isUnseen(recent))
        #expect(!inbox.isUnseen(old))
        #expect(notified.isEmpty, "beim ersten Abruf kein Hinweis")
    }

    @Test func laterAlarmsAndRevisionsAreNew() throws {
        let clock = Clock()
        let inbox = try makeInbox(clock: clock)
        var notified: [AlamosAlarm] = []
        inbox.onNewAlarm = { notified.append($0) }
        let first = alarm(minutesAgo: 120, now: clock.now)
        inbox.apply([first])
        #expect(inbox.unseen.isEmpty)

        let second = alarm(now: clock.now)
        let updatedFirst = alarm(first.id, revision: 2, minutesAgo: 120, now: clock.now)
        inbox.apply([updatedFirst, second])
        #expect(inbox.isUnseen(second))
        #expect(inbox.isUnseen(updatedFirst), "neuer Stand gilt als neu")
        #expect(notified.map(\.id) == [second.id], "Hinweis nur für neue Einsätze")

        inbox.markSeen(second)
        #expect(!inbox.isUnseen(second))

        // Vom Backend gelöscht (Aufbewahrung abgelaufen) → verschwindet.
        inbox.apply([second])
        #expect(inbox.alarms.count == 1)
        #expect(!inbox.isUnseen(updatedFirst))
    }

    /// Schritt 143: neuer Stand eines bekannten Einsatzes → Hinweis mit Kurzfassung.
    @Test func changedAlarmsAreAnnounced() throws {
        let clock = Clock()
        let inbox = try makeInbox(clock: clock)
        var changes: [[String]] = []
        inbox.onChangedAlarm = { changes.append($1) }
        let id = UUID()
        func version(_ revision: Int, closed: Bool = false, vehicles: [AlamosVehicle] = []) -> AlamosAlarm {
            AlamosAlarm(id: id, externalId: "4711", revision: revision, receivedAt: clock.now, closedAt: closed ? clock.now : nil,
                        data: AlamosAlarmData(keyword: "RD 2", vehicles: vehicles))
        }
        inbox.apply([version(1)])
        #expect(changes.isEmpty)
        let vehicles = [AlamosVehicle(radioName: "RK SWFT 71/1")]
        inbox.apply([version(2, vehicles: vehicles)])
        #expect(changes == [["+1 Fahrzeug nachalarmiert: RK SWFT 71/1"]])
        inbox.apply([version(2, vehicles: vehicles)])
        #expect(changes.count == 1, "gleicher Stand → kein Hinweis")
        inbox.apply([version(3, closed: true, vehicles: vehicles)])
        #expect(changes.last == ["In FE2 geschlossen"])
    }

    @Test func filtersClosedAndTests() throws {
        let clock = Clock()
        let inbox = try makeInbox(clock: clock)
        let open = alarm(now: clock.now)
        let closed = alarm(closed: true, now: clock.now)
        let test = alarm(test: true, now: clock.now)
        inbox.apply([open, closed, test])
        #expect(Set(inbox.visibleAlarms.map(\.id)) == [open.id, test.id])
        #expect(!inbox.isUnseen(closed), "geschlossene nie als neu")
        try inbox.updateSettings {
            $0.showsClosed = true
            $0.showsTests = false
        }
        #expect(Set(inbox.visibleAlarms.map(\.id)) == [open.id, closed.id])
    }

    @Test func disablingClearsTheInbox() throws {
        let clock = Clock()
        let inbox = try makeInbox(clock: clock)
        inbox.apply([alarm(now: clock.now)])
        try inbox.updateSettings { $0.isEnabled = false }
        #expect(inbox.alarms.isEmpty)
        #expect(inbox.unseen.isEmpty)
    }

    @Test func apiKeyLivesInSecureStore() async throws {
        let inbox = try makeInbox()
        #expect(!inbox.hasAPIKey)
        try inbox.setAPIKey("  elrd_abc  ")
        #expect(inbox.storedAPIKey == "elrd_abc")
        try inbox.setAPIKey("")
        #expect(!inbox.hasAPIKey)
        // Ohne Adresse/Schlüssel: verständlicher Fehler statt Netzaufruf.
        await #expect(throws: AlamosClientError.self) {
            _ = try await inbox.testConnection(url: "", key: nil)
        }
    }

    @Test func importFormIsPrefilled() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let alarm = AlamosAlarm(
            externalId: "2611-4711",
            receivedAt: now,
            data: AlamosAlarmData(
                keyword: "RD 2",
                keywordDescription: "VU Pkw",
                location: AlamosLocation(street: "Markt", house: "1", postalCode: "97421", city: "Schweinfurt"),
                patients: [AlamosPatient(remark: "eingeklemmt")],
                vehicles: [AlamosVehicle(radioName: "RK SWFT 71/1")]
            )
        )
        var settings = AlamosSettings()
        let form = NewMissionForm.importing(alarm, settings: settings)
        #expect(form.reason == "VU Pkw")
        #expect(form.location == "Markt 1, 97421 Schweinfurt")
        #expect(form.dispatchNumber == "2611-4711")
        #expect(form.importsVehicles && form.importsPatients)
        #expect(form.alarmstichwort == nil, "Fahrzeuge statt Platzhalter")
        let request = form.request(automaticSections: [], masterUnits: [MasterUnit(callsign: "RK SWFT 71/1", type: .rtw)])
        #expect(request.alarmImport?.alarm.externalId == "2611-4711")
        #expect(request.alarmImport?.vehicleMatches.first?.master != nil)

        settings.importsVehicles = false
        settings.importsPatients = false
        let manual = NewMissionForm.importing(alarm, settings: settings)
        #expect(!manual.importsVehicles && !manual.importsPatients)
        #expect(manual.alarmstichwort == .rd2, "ohne Fahrzeuge: Platzhalter aus dem Stichwort")
        #expect(NewMissionForm().request(automaticSections: []).alarmImport == nil)
    }

    @Test func demoInboxHasTwoAlarms() throws {
        let inbox = try makeInbox()
        inbox.loadDemo()
        #expect(inbox.alarms.count == 2)
        #expect(inbox.alarms.first?.data.callsigns.count == 5)
    }
}
