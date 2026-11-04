import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Einsatzliste")
@MainActor
struct MissionOverviewTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func summary(
        _ number: Int,
        reason: String,
        location: String = "",
        dispatch: String? = nil,
        start: Date,
        closed: Bool = true
    ) -> MissionSummary {
        var mission = Mission(
            metadata: .new(by: nil, at: start),
            yearNumber: number,
            dispatchNumber: dispatch,
            reason: reason,
            location: location,
            startedAt: start
        )
        if closed { mission.close(at: start.addingTimeInterval(3_600)) }
        return MissionSummary(mission: mission, patients: [], calendar: calendar)
    }

    // MARK: Anlegen und Löschen

    @Test func newMissionWithAlarmstichwortCreatesPlaceholdersInInitialSection() throws {
        let fixture = try StoreFixture()
        let clock = fixture.clock
        let store = try MissionStore.create(
            NewMissionRequest(
                reason: "VU",
                sectionNames: ["Bereitstellungsraum", "Behandlungsplatz"],
                initialSectionName: "Bereitstellungsraum",
                alarmstichwort: .rd3
            ),
            repository: fixture.repository,
            session: fixture.session(fixture.deviceA),
            clock: try DeviceClock(deviceID: fixture.deviceA.deviceID, repository: fixture.repository),
            now: { clock.now }
        )

        let initial = try #require(store.state.activeSections.first { $0.isInitial })
        let units = store.state.activeUnits
        #expect(units.count == 3, "RD 3: 2 RTW, 1 NEF")
        #expect(units.allSatisfy { $0.sectionID == initial.id })
        #expect(store.state.visibleLog.count == 2, "Einsatz angelegt + Stichwort")

        // Alles in einem Speichervorgang: neu geladen identisch.
        let inMemory = store.state
        try store.reload()
        #expect(store.state == inMemory)
    }

    @Test(arguments: [false, true])
    func deleteMissionHidesItFromList(closedFirst: Bool) throws {
        let fixture = try StoreFixture()
        let keep = try fixture.newMission()
        let remove = try fixture.newMission()
        if closedFirst { try remove.perform(CloseMission()) }

        try remove.perform(DeleteMission())

        let listed = try MissionOverview.load(from: fixture.repository).map(\.id)
        #expect(listed == [keep.missionID])
        let all = try fixture.repository.missions(includeDeleted: true)
        #expect(all.count == 2, "weich gelöscht, nicht entfernt")

        // Die Jahresnummer bleibt vergeben.
        let next = try fixture.newMission()
        #expect(next.state.mission.yearNumber == 3)
    }

    @Test func overviewCountsActivePatients() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        try store.perform(AddPatient(triage: .sk1))
        try store.perform(AddPatient(triage: .sk2))
        try store.perform(AddPatient(triage: .sk2))

        let summary = try #require(try MissionOverview.load(from: fixture.repository).first)
        #expect(summary.patientCount == 3)
        #expect(summary.triageCounts[.sk2] == 2)
        #expect(summary.title == "Test")
        #expect(!summary.isClosed)
    }

    // MARK: Filter

    @Test func runningMissionsAlwaysShownEvenWithSearchAndOtherYear() {
        let now = Self.date(2026, 11, 4)
        let running = Self.summary(9, reason: "Brand", start: Self.date(2025, 12, 31, 23), closed: false)
        let filter = MissionListFilter(showsAllYears: false, searchText: "gibt es nicht")
        let result = filter.apply(to: [running], now: now, calendar: Self.calendar)
        #expect(result.running == [running])
        #expect(result.finished.isEmpty)
    }

    @Test func yearFilterHidesOlderFinishedMissions() {
        let now = Self.date(2026, 11, 4)
        let thisYear = Self.summary(2, reason: "VU", start: Self.date(2026, 3, 1))
        let newer = Self.summary(5, reason: "BMA", start: Self.date(2026, 10, 1))
        let lastYear = Self.summary(7, reason: "VU Bus", start: Self.date(2025, 6, 1))

        let currentOnly = MissionListFilter().apply(to: [thisYear, lastYear, newer], now: now, calendar: Self.calendar)
        #expect(currentOnly.finished.map(\.displayNumber) == ["2026/5", "2026/2"], "neueste zuerst")
        #expect(currentOnly.hiddenByYear == 1)

        let all = MissionListFilter(showsAllYears: true).apply(to: [thisYear, lastYear, newer], now: now, calendar: Self.calendar)
        #expect(all.finished.count == 3)
        #expect(all.hiddenByYear == 0)
    }

    @Test(arguments: [
        ("vu", 2), ("MÜSTER", 2), ("2026/3", 1), ("4711", 1), ("bus muster", 1), ("brand", 0), ("  ", 3)
    ] as [(String, Int)])
    func searchMatchesTitleLocationNumbers(query: String, expected: Int) {
        let now = Self.date(2026, 11, 4)
        let missions = [
            Self.summary(1, reason: "VU", location: "B 19", start: Self.date(2026, 1, 10)),
            Self.summary(2, reason: "BMA Klinik", location: "Musterstadt", dispatch: "4711-26", start: Self.date(2026, 2, 10)),
            Self.summary(3, reason: "VU Bus", location: "Mustérdorf", start: Self.date(2026, 3, 10)),
        ]
        let result = MissionListFilter(searchText: query).apply(to: missions, now: now, calendar: Self.calendar)
        #expect(result.finished.count == expected)
    }
}
