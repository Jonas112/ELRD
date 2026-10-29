import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore
@testable import ELRDSync

/// Steuerbare Uhr für Tests.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct StoreFixture {
    let repository: any EntityRepository
    let clock = TestClock()
    let deviceA = DeviceIdentity(deviceID: DeviceID(), numberPrefix: "A")!
    let deviceB = DeviceIdentity(deviceID: DeviceID(), numberPrefix: "B")!
    let userA = UserID()

    init(kind: RepositoryKindForStore = .inMemory) throws {
        repository = try kind.make()
    }

    func session(_ device: DeviceIdentity, name: String = "Test-Einsatzleiter") -> SessionIdentity {
        SessionIdentity(userID: userA, displayName: name, device: device)
    }

    func newMission(device: DeviceIdentity? = nil, sections: [String] = ["Bereitstellungsraum", "Patientenablage"]) throws -> MissionStore {
        let device = device ?? deviceA
        let clock = self.clock
        return try MissionStore.create(
            NewMissionRequest(reason: "Test", sectionNames: sections, initialSectionName: sections.first),
            repository: repository,
            session: session(device),
            clock: try DeviceClock(deviceID: device.deviceID, repository: repository),
            now: { clock.now }
        )
    }

    func open(_ missionID: MissionID, device: DeviceIdentity) throws -> MissionStore {
        let clock = self.clock
        return try MissionStore(
            missionID: missionID,
            repository: repository,
            session: session(device),
            clock: try DeviceClock(deviceID: device.deviceID, repository: repository),
            now: { clock.now }
        )
    }
}

enum RepositoryKindForStore: String, CaseIterable, Sendable {
    case inMemory
    case swiftData

    @MainActor
    func make() throws -> any EntityRepository {
        switch self {
        case .inMemory: InMemoryRepository()
        case .swiftData: SwiftDataRepository(container: try PersistenceStore.makeInMemoryContainer())
        }
    }
}

@Suite("MissionStore")
@MainActor
struct MissionStoreTests {
    @Test(arguments: RepositoryKindForStore.allCases)
    func createMissionWritesEverythingTogether(kind: RepositoryKindForStore) throws {
        let fixture = try StoreFixture(kind: kind)
        let store = try fixture.newMission()

        #expect(store.state.mission.yearNumber == 1)
        #expect(store.state.mission.commanderID == fixture.userA)
        #expect(store.state.activeSections.map(\.name) == ["Bereitstellungsraum", "Patientenablage"])
        #expect(store.state.activeSections.first?.isInitial == true)
        #expect(store.state.visibleLog.map(\.message) == ["Einsatz \(store.state.mission.displayNumber()) angelegt"])

        let events = try store.changeEvents()
        #expect(events.first?.entityType == .mission, "Einsatz steht zuerst im Journal")
        #expect(events.count == 4, "Einsatz, 2 Abschnitte, 1 Protokolleintrag")
        #expect(events.allSatisfy { $0.operation == .insert })

        let second = try fixture.newMission()
        #expect(second.state.mission.yearNumber == 2)
    }

    @Test(arguments: RepositoryKindForStore.allCases)
    func stateEqualsReloadedState(kind: RepositoryKindForStore) throws {
        let fixture = try StoreFixture(kind: kind)
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk2))
        fixture.clock.advance(60)
        try store.perform(SetTriage(patientID: patient.id, triage: .sk1))
        try store.perform(AddAlarmstichwort(.rd2))
        try store.perform(AddJournalText("Lagemeldung"))

        let inMemory = store.state
        try store.reload()
        #expect(store.state == inMemory)
    }

    @Test func patientsAreNumberedPerDevice() throws {
        let fixture = try StoreFixture()
        let storeA = try fixture.newMission()
        try storeA.perform(AddPatient(triage: .sk1))
        try storeA.perform(AddPatient(triage: .sk3))

        let storeB = try fixture.open(storeA.missionID, device: fixture.deviceB)
        let fromB = try storeB.perform(AddPatient())

        #expect(fromB.number.description == "B-1")
        try storeA.reload()
        #expect(storeA.state.activePatients.map(\.number.description) == ["A-1", "A-2", "B-1"])
    }

    @Test func triageChangeIsVersionedAndLogged() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient())
        fixture.clock.advance(30)
        try store.perform(SetTriage(patientID: patient.id, triage: .sk1))

        let updated = try #require(store.state.patients.first)
        #expect(updated.triage == .sk1)
        #expect(updated.metadata.version == 2)
        #expect(updated.metadata.updatedAt == fixture.clock.now)
        #expect(store.state.visibleLog.last?.message == "Patient A-1: Ungesichtet → Sichtungskategorie 1")
        #expect(store.state.visibleLog.last?.subject == .patient(patient.id))

        let triageEvent = try store.changeEvents().last { $0.entityType == .patient }
        #expect(triageEvent?.changes == [.set(field: "triage", value: .number(1))])

        // Gleiche Kategorie erneut: keine Änderung, kein Protokolleintrag.
        let logCount = store.state.logEntries.count
        try store.perform(SetTriage(patientID: patient.id, triage: .sk1))
        #expect(store.state.logEntries.count == logCount)
    }

    @Test func alarmstichwortGoesToInitialSection() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let units = try store.perform(AddAlarmstichwort(.rd3))
        let initial = try #require(MissionSection.initialSection(in: store.state.sections))
        #expect(units.map(\.displayName) == ["RTW (Platzhalter 1)", "RTW (Platzhalter 2)", "NEF (Platzhalter 3)"])
        let allInInitial = units.allSatisfy { $0.sectionID == initial.id }
        #expect(allInInitial)
    }

    @Test func closedMissionIsReadOnlyUntilReopened() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        fixture.clock.advance(3600)
        try store.perform(CloseMission())

        #expect(store.state.mission.isClosed)
        #expect(store.state.mission.endedAt == fixture.clock.now)
        let closingEntry = try #require(store.state.chronologicalJournal.last)
        #expect(closingEntry.text == "Einsatz / Lage wurde durch Test-Einsatzleiter beendet.")
        #expect(closingEntry.origin == .automatic)
        #expect(closingEntry.number.description == "A-1")

        #expect(throws: CommandError.missionClosed) { try store.perform(AddPatient()) }
        #expect(throws: CommandError.missionClosed) { try store.perform(CloseMission()) }

        try store.perform(ReopenMission())
        #expect(!store.state.mission.isClosed)
        #expect(throws: CommandError.missionNotClosed) { try store.perform(ReopenMission()) }
        try store.perform(AddPatient())
    }

    @Test func invalidEditIsRejected() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let before = store.state
        let start = store.state.mission.startedAt
        #expect(throws: CommandError.self) {
            try store.perform(EditMission { $0.endedAt = start.addingTimeInterval(-60) })
        }
        #expect(store.state == before)

        try store.perform(EditMission { $0.reason = "VU B19" })
        #expect(store.state.mission.reason == "VU B19")
        #expect(store.state.visibleLog.last?.message == "Einsatzdaten geändert")
    }

    @Test func failingCommandOrStorageChangesNothing() throws {
        let repository = InMemoryRepository()
        let session = SessionIdentity(
            userID: nil,
            displayName: "Test",
            device: DeviceIdentity(deviceID: DeviceID(), numberPrefix: "A")!
        )
        let store = try MissionStore.create(
            NewMissionRequest(),
            repository: repository,
            session: session,
            clock: try DeviceClock(deviceID: session.device.deviceID, repository: repository)
        )
        let before = store.state

        #expect(throws: CommandError.notFound(.patient)) {
            try store.perform(SetTriage(patientID: PatientID(), triage: .sk1))
        }
        #expect(store.state == before)

        repository.failNextApply = true
        #expect(throws: InMemoryRepositoryError.self) { try store.perform(AddPatient()) }
        #expect(store.state == before)
        try store.reload()
        #expect(store.state == before)
    }

    @Test func secondWindowRetriesOnConflict() throws {
        let fixture = try StoreFixture()
        let window1 = try fixture.newMission()
        let patient = try window1.perform(AddPatient())
        let window2 = try fixture.open(window1.missionID, device: fixture.deviceA)

        // Fenster 1 ändert den Patienten; Fenster 2 kennt diese Änderung noch nicht.
        fixture.clock.advance(10)
        try window1.perform(SetTriage(patientID: patient.id, triage: .sk2))
        fixture.clock.advance(10)
        try window2.perform(SetTriage(patientID: patient.id, triage: .sk1))

        let final = try #require(window2.state.patients.first)
        #expect(final.triage == .sk1)
        #expect(final.metadata.version == 3, "Fenster 2 hat neu geladen und auf Version 2 aufgesetzt")
        let log = window2.state.visibleLog.map(\.message)
        #expect(log.contains("Patient A-1: Sichtungskategorie 2 → Sichtungskategorie 1"))
    }

    @Test func clockContinuesAfterRestart() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        try store.perform(AddPatient())
        let timestampsBefore = try store.changeEvents().map(\.timestamp)
        let lastBefore = try #require(timestampsBefore.max())

        // „Neustart“ mit zurückgestellter Uhr: neue Zeitstempel müssen trotzdem später sein.
        fixture.clock.advance(-3600)
        let restarted = try fixture.open(store.missionID, device: fixture.deviceA)
        try restarted.perform(AddPatient())
        let timestampsAfter = try restarted.changeEvents().map(\.timestamp)
        let newest = try #require(timestampsAfter.max())
        #expect(newest > lastBefore)
    }

    @Test func logStaysChronologicalWithinSameMillisecond() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        // Uhr steht still: alle Aktionen in derselben Millisekunde.
        for triage in [Sichtungskategorie.sk1, .sk2, .sk3] {
            try store.perform(AddPatient(triage: triage))
        }
        let messages = store.state.visibleLog.map(\.message)
        #expect(messages == [
            "Einsatz \(store.state.mission.displayNumber()) angelegt",
            "Patient A-1 angelegt – Sichtungskategorie 1",
            "Patient A-2 angelegt – Sichtungskategorie 2",
            "Patient A-3 angelegt – Sichtungskategorie 3",
        ])
        let timestamps = store.state.visibleLog.map(\.timestamp)
        #expect(timestamps == timestamps.sorted())
        #expect(Set(timestamps).count == timestamps.count)
    }

    @Test func previewDataIsComplete() throws {
        let store = try PreviewData.makeStore()
        #expect(store.state.activeSections.count == 3)
        #expect(store.state.activeUnits.count == 3)
        #expect(store.state.activePatients.count == 7)
        #expect(Patient.countsByTriage(store.state.patients)[.sk3] == 3)
        #expect(store.state.chronologicalJournal.count == 1)
        let noNames = store.state.patients.allSatisfy { $0.fullName.isEmpty }
        #expect(noNames)
    }
}
