import Foundation
import Testing
@testable import ELRDCloud
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore
@testable import ELRDSync

/// Uhr der Tests (frei verstellbar).
@MainActor
final class CloudTestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Ein Gerät mit eigenem Speicher, angemeldet mit einem iCloud-Konto.
@MainActor
final class CloudDevice {
    let repository = InMemoryRepository()
    let identity: DeviceIdentity
    let deviceClock: DeviceClock
    let session: SessionIdentity
    let files = AttachmentFileStore.temporary()
    let cloud: FakeCloudZoneStore
    let coordinator: CloudSyncCoordinator
    let clock: CloudTestClock
    private(set) var importedNotices: [Set<MissionID>] = []

    init(prefix: String, account: String?, server: FakeCloudServer, clock: CloudTestClock) throws {
        identity = DeviceIdentity(deviceID: DeviceID(), numberPrefix: prefix)!
        deviceClock = try DeviceClock(deviceID: identity.deviceID, repository: repository)
        session = SessionIdentity(userID: UserID(), displayName: "Gerät \(prefix)", device: identity)
        cloud = FakeCloudZoneStore(server: server, account: account)
        self.clock = clock
        coordinator = CloudSyncCoordinator(
            repository: repository,
            clock: deviceClock,
            deviceID: identity.deviceID,
            files: files,
            store: cloud,
            now: { clock.now },
            // Wartezeiten laufen in den Tests nie von selbst ab.
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        coordinator.onImported = { [weak self] missions in self?.importedNotices.append(missions) }
    }

    func createMission() throws -> MissionStore {
        let clock = self.clock
        return try MissionStore.create(
            NewMissionRequest(reason: "MANV Bahnhof", sectionNames: ["Patientenablage"], initialSectionName: "Patientenablage"),
            repository: repository,
            session: session,
            clock: deviceClock,
            now: { clock.now }
        )
    }

    func open(_ missionID: MissionID) throws -> MissionStore {
        let clock = self.clock
        return try MissionStore(missionID: missionID, repository: repository, session: session, clock: deviceClock, now: { clock.now })
    }

    func checkpoint(_ mission: MissionID) throws -> SyncCheckpoint {
        try (repository.document(SyncCheckpoints.self, key: .syncCheckpoints) ?? SyncCheckpoints())[mission]
    }
}

@Suite("iCloud-Teilen: Ablauf und Wettläufe")
@MainActor
struct CloudSyncTests {
    let server = FakeCloudServer()
    let clock = CloudTestClock()

    private func device(_ prefix: String, _ account: String?) throws -> CloudDevice {
        try CloudDevice(prefix: prefix, account: account, server: server, clock: clock)
    }

    /// Eigentümer teilt, zweites Konto tritt bei.
    private func sharedPair() async throws -> (owner: CloudDevice, guest: CloudDevice, store: MissionStore, url: URL) {
        let owner = try device("A", "alice")
        let guest = try device("B", "bob")
        let store = try owner.createMission()
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV Bahnhof")
        await owner.coordinator.syncNow(store.missionID)
        let joined = try await guest.coordinator.join(url)
        #expect(joined == store.missionID)
        return (owner, guest, store, url)
    }

    // MARK: Grundablauf

    @Test func ownerSharesAndOtherAccountJoins() async throws {
        let owner = try device("A", "alice")
        let guest = try device("B", "bob")
        let store = try owner.createMission()
        let patient = try store.perform(AddPatient(triage: .sk1))
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV Bahnhof")
        await owner.coordinator.syncNow(store.missionID)
        #expect(owner.coordinator.state(for: store.missionID).phase == .idle)
        #expect(owner.coordinator.pendingCount(for: store.missionID) == 0)

        let mission = try await guest.coordinator.join(url)
        let copy = try guest.open(mission)
        #expect(copy.state.activePatients.map(\.id) == [patient.id])
        #expect(guest.coordinator.link(for: mission)?.zone.scope == .joined)
        #expect(guest.coordinator.link(for: mission)?.shareURL == url, "Beigetretene können weiter einladen")

        // Zurück: Änderung des Gasts erreicht den Eigentümer.
        let second = try copy.perform(AddPatient(triage: .sk2))
        await guest.coordinator.syncNow(mission)
        await owner.coordinator.syncNow(mission)
        try store.reload()
        #expect(Set(store.state.activePatients.map(\.id)) == [patient.id, second.id])
        #expect(owner.importedNotices.contains([mission]), "offene Ansichten werden neu geladen")
    }

    @Test func filesTravelThroughICloud() async throws {
        let owner = try device("A", "alice")
        let guest = try device("B", "bob")
        let store = try owner.createMission()
        let photo = try owner.files.save(Data("Foto".utf8), kind: .photo, createdAt: clock.now)
        try store.perform(AddJournalMedia(attachments: [photo], text: "Lage"))
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        await owner.coordinator.syncNow(store.missionID)
        _ = try await guest.coordinator.join(url)
        #expect(guest.files.isIntact(photo))
    }

    // MARK: Doppelte Aktionen

    @Test func doubleTapOnShareCreatesOneShare() async throws {
        let owner = try device("A", "alice")
        let store = try owner.createMission()
        await server.setDelay(.milliseconds(30))
        let first = Task { try await owner.coordinator.startSharing(store.missionID, title: "MANV") }
        let second = Task { try await owner.coordinator.startSharing(store.missionID, title: "MANV") }
        let one = try await first.value
        let two = try await second.value
        #expect(one == two)
        #expect(await server.sharesCreated == 1)
    }

    @Test func twoDevicesOfOneAccountShareTheSameZone() async throws {
        let first = try device("A", "alice")
        let second = try device("C", "alice")
        let store = try first.createMission()
        // Zweites iPad desselben Kontos hat den Einsatz schon (z. B. als Datei).
        let archive = try MissionArchive.make(mission: store.missionID, repository: first.repository, files: nil, now: clock.now)
        _ = try archive.importInto(repository: second.repository, clock: second.deviceClock, files: nil)

        await server.setDelay(.milliseconds(30))
        let a = Task { try await first.coordinator.startSharing(store.missionID, title: "MANV") }
        let b = Task { try await second.coordinator.startSharing(store.missionID, title: "MANV") }
        let urlA = try await a.value
        let urlB = try await b.value
        #expect(urlA == urlB, "gleichzeitig freigegeben – eine Freigabe")
        #expect(await server.sharesCreated == 1)
        #expect(first.coordinator.link(for: store.missionID)?.zone == second.coordinator.link(for: store.missionID)?.zone)
    }

    @Test func openingTheLinkTwiceJoinsOnce() async throws {
        let owner = try device("A", "alice")
        let guest = try device("B", "bob")
        let store = try owner.createMission()
        try store.perform(AddPatient(triage: .sk1))
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        await owner.coordinator.syncNow(store.missionID)

        await server.setDelay(.milliseconds(20))
        let first = Task { try await guest.coordinator.join(url) }
        let second = Task { try await guest.coordinator.join(url) }
        let one = try await first.value
        let two = try await second.value
        #expect(one == two)
        let events = try guest.repository.changeEvents(in: one)
        #expect(Set(events.map(\.id)).count == events.count, "nichts doppelt")
        #expect(try guest.open(one).state.activePatients.count == 1)
    }

    @Test func ownLinkOnOwnDeviceIsHarmless() async throws {
        let owner = try device("A", "alice")
        let store = try owner.createMission()
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        let mission = try await owner.coordinator.join(url)
        #expect(mission == store.missionID)
        #expect(owner.coordinator.link(for: mission)?.isOwner == true)
    }

    // MARK: Überschneidungen beim Abgleich

    @Test func changesDuringSyncAreNotLost() async throws {
        let (owner, guest, store, _) = try await sharedPair()
        await server.setDelay(.milliseconds(40))
        let running = Task { await owner.coordinator.syncNow(store.missionID) }
        await Task.yield()
        let patient = try store.perform(AddPatient(triage: .sk1))
        owner.coordinator.requestSync(store.missionID)
        await running.value
        // Der Folgelauf läuft unabhängig; zuverlässig abwarten.
        await owner.coordinator.syncNow(store.missionID)
        #expect(owner.coordinator.pendingCount(for: store.missionID) == 0)

        await server.setDelay(.zero)
        await guest.coordinator.syncNow(store.missionID)
        #expect(try guest.open(store.missionID).state.activePatients.map(\.id) == [patient.id])
    }

    @Test func leavingDuringSyncDoesNotResurrectState() async throws {
        let (_, guest, store, _) = try await sharedPair()
        await server.setDelay(.milliseconds(40))
        let running = Task { await guest.coordinator.syncNow(store.missionID) }
        await Task.yield()
        try await guest.coordinator.disconnect(store.missionID)
        await running.value

        #expect(guest.coordinator.link(for: store.missionID) == nil)
        #expect(try guest.checkpoint(store.missionID) == SyncCheckpoint(), "kein verspäteter Lauf schreibt den Stand zurück")
        #expect(try guest.open(store.missionID).state.mission.reason == "MANV Bahnhof", "lokale Kopie bleibt")
        guest.coordinator.requestSync(store.missionID)
        #expect(guest.coordinator.state(for: store.missionID).phase == .idle)
    }

    @Test func expiredTokenStartsOverWithoutDuplicates() async throws {
        let (owner, guest, store, _) = try await sharedPair()
        let patient = try store.perform(AddPatient(triage: .sk1))
        await owner.coordinator.syncNow(store.missionID)
        await server.expireTokens()
        await guest.coordinator.syncNow(store.missionID)
        #expect(guest.coordinator.state(for: store.missionID).phase == .idle)
        let copy = try guest.open(store.missionID)
        #expect(copy.state.activePatients.map(\.id) == [patient.id])
        let events = try guest.repository.changeEvents(in: store.missionID)
        #expect(Set(events.map(\.id)).count == events.count)
    }

    @Test func largeBatchesAreSplit() async throws {
        let owner = try device("A", "alice")
        let store = try owner.createMission()
        for _ in 0..<12 { try store.perform(AddPatient(triage: .sk3)) }
        await server.setMaxBatch(7)
        _ = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        await owner.coordinator.syncNow(store.missionID)
        #expect(owner.coordinator.state(for: store.missionID).phase == .idle)
        let zone = try #require(owner.coordinator.link(for: store.missionID)?.zone)
        let total = try owner.repository.changeEvents(in: store.missionID).count
        #expect(await server.eventCount(owner: "alice", zoneName: zone.zoneName) == total)
    }

    @Test func failedBatchLeavesNothingHalfDone() async throws {
        let owner = try device("A", "alice")
        let store = try owner.createMission()
        try store.perform(AddPatient(triage: .sk1))
        await server.fail(.save, with: .network)
        _ = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        await owner.coordinator.syncNow(store.missionID)
        let zone = try #require(owner.coordinator.link(for: store.missionID)?.zone)
        #expect(owner.coordinator.state(for: store.missionID).phase == .waiting)
        #expect(await server.eventCount(owner: "alice", zoneName: zone.zoneName) == 0, "atomar: nichts halb gespeichert")
        #expect(owner.coordinator.pendingCount(for: store.missionID) > 0)

        await owner.coordinator.syncNow(store.missionID)
        let total = try owner.repository.changeEvents(in: store.missionID).count
        #expect(await server.eventCount(owner: "alice", zoneName: zone.zoneName) == total)
        #expect(owner.coordinator.state(for: store.missionID).phase == .idle)
    }

    // MARK: Wartezeiten

    @Test func rateLimitWaitsInsteadOfHammering() async throws {
        let (owner, _, store, _) = try await sharedPair()
        try store.perform(AddPatient(triage: .sk1))
        await server.fail(.save, with: .retry(after: 30))
        await owner.coordinator.syncNow(store.missionID)
        let state = owner.coordinator.state(for: store.missionID)
        #expect(state.phase == .waiting)
        #expect(state.retryAt == clock.now.addingTimeInterval(30))

        let callsBefore = await server.saveCalls
        for _ in 0..<5 { owner.coordinator.requestSync(store.missionID) }
        for _ in 0..<5 { await Task.yield() }
        #expect(await server.saveCalls == callsBefore, "keine Anfragen während der Wartezeit")

        clock.advance(31)
        await owner.coordinator.syncNow(store.missionID)
        #expect(owner.coordinator.state(for: store.missionID).phase == .idle)
        #expect(owner.coordinator.pendingCount(for: store.missionID) == 0)
    }

    @Test func backoffGrowsAndResetsAfterSuccess() async throws {
        let (owner, _, store, _) = try await sharedPair()
        try store.perform(AddPatient(triage: .sk1))
        await server.fail(.save, with: .network)
        await owner.coordinator.syncNow(store.missionID)
        let first = try #require(owner.coordinator.state(for: store.missionID).retryAt)
        await server.fail(.save, with: .network)
        await owner.coordinator.syncNow(store.missionID)
        let second = try #require(owner.coordinator.state(for: store.missionID).retryAt)
        #expect(second.timeIntervalSince(clock.now) > first.timeIntervalSince(clock.now))
        await owner.coordinator.syncNow(store.missionID)
        #expect(owner.coordinator.state(for: store.missionID).retryAt == nil)
    }

    // MARK: Freigabe, Konto, Schlüssel

    @Test func endedShareKeepsLocalDataAndStopsSyncing() async throws {
        let (_, guest, store, _) = try await sharedPair()
        let zone = try #require(guest.coordinator.link(for: store.missionID)?.zone)
        await server.stopSharing(owner: zone.ownerName, zoneName: zone.zoneName)
        await guest.coordinator.syncNow(store.missionID)
        #expect(guest.coordinator.state(for: store.missionID).phase == .revoked)
        #expect(try guest.open(store.missionID).state.mission.reason == "MANV Bahnhof")

        let callsBefore = await server.saveCalls
        guest.coordinator.requestSync(store.missionID)
        for _ in 0..<5 { await Task.yield() }
        #expect(await server.saveCalls == callsBefore)

        // Trennen räumt auf, auch wenn die Freigabe schon weg ist.
        try await guest.coordinator.disconnect(store.missionID)
        #expect(guest.coordinator.link(for: store.missionID) == nil)
    }

    @Test func accountSwitchDropsLinksButKeepsMissions() async throws {
        let (_, guest, store, _) = try await sharedPair()
        guest.cloud.switchAccount(to: "carol")
        await guest.coordinator.accountDidChange()
        #expect(guest.coordinator.link(for: store.missionID) == nil)
        #expect(try guest.checkpoint(store.missionID) == SyncCheckpoint())
        #expect(try guest.open(store.missionID).state.mission.reason == "MANV Bahnhof")
    }

    @Test func signedOutShowsProblemAndKeepsLinks() async throws {
        let (_, guest, store, _) = try await sharedPair()
        guest.cloud.switchAccount(to: nil)
        await guest.coordinator.accountDidChange()
        #expect(guest.coordinator.accountProblem != nil)
        #expect(guest.coordinator.link(for: store.missionID) != nil, "nach erneuter Anmeldung geht es weiter")

        guest.cloud.switchAccount(to: "bob")
        await guest.coordinator.accountDidChange()
        #expect(guest.coordinator.accountProblem == nil)
        await guest.coordinator.syncNow(store.missionID)
        #expect(guest.coordinator.state(for: store.missionID).phase == .idle)
    }

    @Test func keyResetRebuildsOwnersCloudCopy() async throws {
        let owner = try device("A", "alice")
        let store = try owner.createMission()
        _ = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        await owner.coordinator.syncNow(store.missionID)
        let zone = try #require(owner.coordinator.link(for: store.missionID)?.zone)
        await server.resetKeys(owner: "alice", zoneName: zone.zoneName)

        try store.perform(AddPatient(triage: .sk1))
        await owner.coordinator.syncNow(store.missionID)
        #expect(owner.coordinator.state(for: store.missionID).phase == .idle)
        let total = try owner.repository.changeEvents(in: store.missionID).count
        #expect(await server.eventCount(owner: "alice", zoneName: zone.zoneName) == total, "alles neu hochgeladen")
    }

    @Test func invalidLinkIsRejected() async throws {
        let guest = try device("B", "bob")
        await #expect(throws: CloudStoreError.invalidShare) {
            _ = try await guest.coordinator.join(URL(string: "https://www.icloud.com/share/x#nobody/nothing")!)
        }
    }

    @Test func noICloudAccountBlocksSharing() async throws {
        let owner = try device("A", nil)
        let store = try owner.createMission()
        await #expect(throws: CloudShareError.self) {
            _ = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        }
        #expect(owner.coordinator.link(for: store.missionID) == nil)
    }

    // MARK: App-Anbindung

    @Test func storeReportsEachCommit() throws {
        let owner = try device("A", "alice")
        let store = try owner.createMission()
        var reported: [MissionID] = []
        store.didCommit = { reported.append($0) }
        try store.perform(AddPatient(triage: .sk1))
        try store.perform(AddPatient(triage: .sk2))
        #expect(reported == [store.missionID, store.missionID])
    }

    @Test func demoStoreSupportsSharingFlow() async throws {
        let owner = try device("A", "alice")
        let store = try owner.createMission()
        let demo = CloudSyncCoordinator(
            repository: owner.repository,
            clock: owner.deviceClock,
            deviceID: owner.identity.deviceID,
            files: owner.files,
            store: InMemoryCloudZoneStore()
        )
        let url = try await demo.startSharing(store.missionID, title: "MANV")
        await demo.syncNow(store.missionID)
        #expect(demo.state(for: store.missionID).phase == .idle)
        #expect(demo.pendingCount(for: store.missionID) == 0)
        #expect(try await demo.join(url) == store.missionID)
    }

    // MARK: Transport

    @Test func zoneNameRoundTripsMissionID() {
        let mission = MissionID()
        #expect(CloudZone.owned(mission).missionID == mission)
        #expect(CloudZone(scope: .joined, zoneName: "fremd", ownerName: "x").missionID == nil)
    }

    @Test func errorsMapToSyncContract() {
        #expect(CloudStoreError.zoneMissing.syncError(scope: .joined) == .missionNotShared)
        #expect(CloudStoreError.tokenExpired.syncError(scope: .owned) == .cursorExpired)
        #expect(CloudStoreError.retry(after: 7).syncError(scope: .owned) == .retryLater(seconds: 7))
        #expect(CloudStoreError.quotaExceeded.syncError(scope: .owned) == .storageFull)
        #expect(CloudStoreError.keyReset.syncError(scope: .owned) == .encryptionReset)
        #expect(CloudStoreError.network.syncError(scope: .joined) == .offline)
    }
}
