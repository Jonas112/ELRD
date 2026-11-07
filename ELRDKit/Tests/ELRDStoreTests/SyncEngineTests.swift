import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore
@testable import ELRDSync

/// Ein Gerät mit eigenem Speicher, eigener Uhr und Verbindung zum gemeinsamen Server.
@MainActor
private struct SyncDevice {
    let repository = InMemoryRepository()
    let identity: DeviceIdentity
    let deviceClock: DeviceClock
    let engine: SyncEngine
    let session: SessionIdentity
    let clock: TestClock
    let files = AttachmentFileStore.temporary()

    init(prefix: String, server: InMemorySyncServer, clock: TestClock) throws {
        identity = DeviceIdentity(deviceID: DeviceID(), numberPrefix: prefix)!
        deviceClock = try DeviceClock(deviceID: identity.deviceID, repository: repository)
        engine = SyncEngine(repository: repository, transport: server, clock: deviceClock, deviceID: identity.deviceID, files: files, now: { clock.now })
        session = SessionIdentity(userID: UserID(), displayName: "Gerät \(prefix)", device: identity)
        self.clock = clock
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
}

@Suite("Abgleich zwischen Geräten (Schritt 53)")
@MainActor
struct SyncEngineTests {
    let server = InMemorySyncServer()
    let clock = TestClock()

    @Test func secondDeviceReceivesMissionAndPatients() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        let patient = try storeA.perform(AddPatient(triage: .sk1))
        try storeA.perform(EditPatient(patientID: patient.id) { $0.firstName = "Max" })

        let pushed = try await a.engine.sync(storeA.missionID)
        let ownEvents = try a.repository.changeEvents(in: storeA.missionID).count
        #expect(pushed.pushed == ownEvents)
        #expect(await server.eventCount(mission: storeA.missionID) == ownEvents)
        #expect(try a.engine.pendingCount(for: storeA.missionID) == 0)

        let received = try await b.engine.sync(storeA.missionID)
        #expect(received.imported.newEvents == ownEvents)
        let storeB = try b.open(storeA.missionID)
        #expect(storeB.state.mission.reason == "MANV Bahnhof")
        #expect(storeB.state.activeSections.map(\.name) == ["Patientenablage"])
        let copy = try #require(storeB.state.activePatients.first)
        #expect(copy.id == patient.id)
        #expect(copy.firstName == "Max")
        #expect(copy.triage == .sk1)
        #expect(copy.number.description == patient.number.description)

        // Erneut abgleichen ändert nichts (idempotent).
        let again = try await b.engine.sync(storeA.missionID)
        #expect(again.imported.newEvents == 0)
        #expect(again.pushed == 0)
    }

    @Test func concurrentEditsOfDifferentFieldsBothSurvive() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        let patient = try storeA.perform(AddPatient(triage: .sk2))
        try await a.engine.sync(storeA.missionID)
        try await b.engine.sync(storeA.missionID)
        let storeB = try b.open(storeA.missionID)

        // Gleichzeitig, ohne Verbindung: A trägt den Namen ein, B ändert die Sichtung.
        clock.advance(30)
        try storeA.perform(EditPatient(patientID: patient.id) { $0.lastName = "Mustermann" })
        try storeB.perform(SetTriage(patientID: patient.id, triage: .sk1))

        try await a.engine.sync(storeA.missionID)
        try await b.engine.sync(storeA.missionID)
        try await a.engine.sync(storeA.missionID)
        try storeA.reload()
        try storeB.reload()

        for store in [storeA, storeB] {
            let merged = try #require(store.state.activePatients.first { $0.id == patient.id })
            #expect(merged.lastName == "Mustermann")
            #expect(merged.triage == .sk1)
        }
        // Danach geht es lokal normal weiter (keine Versionskonflikte).
        try storeA.perform(EditPatient(patientID: patient.id) { $0.firstName = "Erika" })
        #expect(storeA.state.activePatients.first { $0.id == patient.id }?.firstName == "Erika")
    }

    @Test func deletionWinsOverConcurrentEdit() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        let patient = try storeA.perform(AddPatient(triage: .sk3))
        try await a.engine.sync(storeA.missionID)
        try await b.engine.sync(storeA.missionID)
        let storeB = try b.open(storeA.missionID)

        clock.advance(10)
        try storeB.perform(EditPatient(patientID: patient.id) { $0.lastName = "Später" })
        clock.advance(10)
        try storeA.perform(DeletePatient(patientID: patient.id))

        try await b.engine.sync(storeA.missionID)
        try await a.engine.sync(storeA.missionID)
        try await b.engine.sync(storeA.missionID)
        try storeA.reload()
        try storeB.reload()

        for store in [storeA, storeB] {
            #expect(!store.state.activePatients.contains { $0.id == patient.id })
            let deleted = try #require(store.state.patients.first { $0.id == patient.id })
            #expect(deleted.isDeleted)
            #expect(deleted.lastName == "Später", "Bearbeitung bleibt erhalten, hebt das Löschen aber nicht auf")
        }
    }

    @Test func journalNumbersStayDistinctAcrossDevices() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        try await a.engine.sync(storeA.missionID)
        try await b.engine.sync(storeA.missionID)
        let storeB = try b.open(storeA.missionID)

        try storeA.perform(AddJournalText("Erstmeldung an ILS"))
        try storeB.perform(AddJournalText("Patientenablage eingerichtet"))
        try await a.engine.sync(storeA.missionID)
        try await b.engine.sync(storeA.missionID)
        try await a.engine.sync(storeA.missionID)
        try storeA.reload()
        try storeB.reload()

        let numbersA = storeA.state.journal.active.map(\.number.description)
        let numbersB = storeB.state.journal.active.map(\.number.description)
        #expect(Set(numbersA) == Set(numbersB))
        #expect(Set(numbersA).count == numbersA.count, "keine doppelten Nummern")
        #expect(storeA.state.journal.active.contains { $0.text == "Patientenablage eingerichtet" })
    }

    @Test func interruptedSyncResumesWithoutDuplicates() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let storeA = try a.createMission()
        try storeA.perform(AddPatient(triage: .sk1))

        await server.failNextCall(with: .offline)
        await #expect(throws: SyncError.offline) {
            try await a.engine.sync(storeA.missionID)
        }
        let pending = try a.engine.pendingCount(for: storeA.missionID)
        #expect(pending > 0, "nichts verloren, bleibt zum Hochladen vorgemerkt")

        try await a.engine.sync(storeA.missionID)
        #expect(try a.engine.pendingCount(for: storeA.missionID) == 0)
        let total = try a.repository.changeEvents(in: storeA.missionID).count
        #expect(await server.eventCount(mission: storeA.missionID) == total)
        #expect(try a.engine.checkpoint(for: storeA.missionID).lastSyncAt == clock.now)
    }

    @Test func importOrderDoesNotMatter() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let storeA = try a.createMission()
        let patient = try storeA.perform(AddPatient(triage: .sk2))
        clock.advance(5)
        try storeA.perform(EditPatient(patientID: patient.id) { $0.firstName = "Anna" })
        clock.advance(5)
        try storeA.perform(SetTriage(patientID: patient.id, triage: .sk1))
        let events = try a.repository.changeEvents(in: storeA.missionID)

        let forward = try SyncDevice(prefix: "C", server: server, clock: clock)
        let backward = try SyncDevice(prefix: "D", server: server, clock: clock)
        try RemoteChangeImporter(repository: forward.repository, clock: forward.deviceClock).importEvents(events)
        for event in events.reversed() {
            try RemoteChangeImporter(repository: backward.repository, clock: backward.deviceClock).importEvents([event])
        }
        let one = try #require(try forward.repository.entity(Patient.self, id: patient.id.rawValue))
        let other = try #require(try backward.repository.entity(Patient.self, id: patient.id.rawValue))
        #expect(one.firstName == "Anna" && other.firstName == "Anna")
        #expect(one.triage == .sk1 && other.triage == .sk1)
    }

    @Test func photosAndVoiceNotesFollowTheirEntries() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        let photo = try a.files.save(Data("JPEG-Inhalt".utf8), kind: .photo, createdAt: clock.now, pixelWidth: 4, pixelHeight: 3)
        let voice = try a.files.save(Data("M4A-Inhalt".utf8), kind: .audio, createdAt: clock.now, duration: 4)
        try storeA.perform(AddJournalMedia(attachments: [photo], text: "Einsatzstelle", occurredAt: nil))
        try storeA.perform(AddJournalMedia(attachments: [voice], text: "", occurredAt: nil))

        let sent = try await a.engine.sync(storeA.missionID)
        #expect(sent.filesUploaded == 2)
        #expect(await server.fileCount(mission: storeA.missionID) == 2)

        #expect(try b.engine.missingFiles(for: storeA.missionID).isEmpty, "vor dem Abgleich kennt B den Einsatz nicht")
        let received = try await b.engine.sync(storeA.missionID)
        #expect(received.filesDownloaded == 2)
        #expect(received.filesMissing == 0)
        #expect(b.files.isIntact(photo))
        #expect(b.files.data(for: voice) == Data("M4A-Inhalt".utf8))
        #expect(try b.engine.missingFiles(for: storeA.missionID).isEmpty)

        // Nochmal: nichts mehr zu übertragen.
        let again = try await b.engine.sync(storeA.missionID)
        #expect(again.filesUploaded == 0 && again.filesDownloaded == 0)
    }

    @Test func fileNotYetUploadedIsReportedMissing() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        let photo = try a.files.save(Data("Foto".utf8), kind: .photo, createdAt: clock.now)
        try storeA.perform(AddJournalMedia(attachments: [photo], text: "", occurredAt: nil))
        // A hat nur die Ereignisse übertragen, die Datei ist verloren gegangen.
        try FileManager.default.removeItem(at: a.files.url(for: photo))
        try await a.engine.sync(storeA.missionID)

        let received = try await b.engine.sync(storeA.missionID)
        #expect(received.filesMissing == 1)
        #expect(try b.engine.missingFiles(for: storeA.missionID) == [photo])
    }

    @Test func damagedFileIsRejected() throws {
        let store = AttachmentFileStore.temporary()
        let original = try store.save(Data("echt".utf8), kind: .photo, createdAt: Date())
        let other = AttachmentFileStore.temporary()
        #expect(throws: AttachmentStoreError.checksumMismatch) {
            try other.store(Data("gefälscht".utf8), for: original)
        }
        try other.store(Data("echt".utf8), for: original)
        #expect(other.isIntact(original))
    }

    @Test func localOnlyTransportReportsNotConnected() async throws {
        let device = try SyncDevice(prefix: "A", server: server, clock: clock)
        let store = try device.createMission()
        let local = SyncEngine(repository: device.repository, transport: LocalOnlyTransport(), clock: device.deviceClock, deviceID: device.identity.deviceID)
        await #expect(throws: SyncError.notConnected) {
            try await local.sync(store.missionID)
        }
        #expect(SyncError.notConnected.errorDescription?.contains("bleibt auf diesem Gerät") == true)
    }
}

@Suite("Einsatz als Datei und endgültig löschen (Schritt 63)")
@MainActor
struct MissionArchiveTests {
    let server = InMemorySyncServer()
    let clock = TestClock()

    @Test func archiveMovesMissionToAnotherDevice() throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let store = try a.createMission()
        let patient = try store.perform(AddPatient(triage: .sk1))
        let photo = try a.files.save(Data("Foto".utf8), kind: .photo, createdAt: clock.now)
        try store.perform(AddJournalMedia(attachments: [photo], text: "Lage"))
        let deleted = try store.perform(AddPatient(triage: .sk3))
        try store.perform(DeletePatient(patientID: deleted.id))

        let archive = try MissionArchive.make(mission: store.missionID, repository: a.repository, files: a.files, now: clock.now)
        #expect(archive.suggestedFileName.hasSuffix(".elrdeinsatz"))
        #expect(!archive.suggestedFileName.contains("/"))
        let data = try archive.encoded()

        let opened = try MissionArchive.decode(data)
        let result = try opened.importInto(repository: b.repository, clock: b.deviceClock, files: b.files)
        #expect(result.missionID == store.missionID)
        #expect(result.imported.newEvents == archive.events.count)
        #expect(result.filesStored == 1)
        #expect(b.files.isIntact(photo))

        let copy = try b.open(store.missionID)
        #expect(copy.state.activePatients.map(\.id) == [patient.id])
        #expect(copy.state.trash.count == 1, "Gelöschtes bleibt gelöscht und wiederherstellbar")

        let again = try opened.importInto(repository: b.repository, clock: b.deviceClock, files: b.files)
        #expect(again.imported.newEvents == 0, "zweites Öffnen ändert nichts")
        #expect(again.filesStored == 0)
    }

    @Test func brokenOrNewerFilesAreRejected() throws {
        #expect(throws: MissionArchiveError.unreadable) {
            try MissionArchive.decode(Data("kein Einsatz".utf8))
        }
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let store = try a.createMission()
        let archive = try MissionArchive.make(mission: store.missionID, repository: a.repository, files: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any])
        json["format"] = MissionArchive.currentFormat + 1
        let newer = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: MissionArchiveError.newerFormat) {
            try MissionArchive.decode(newer)
        }
    }

    @Test func purgeRemovesOnlyDeletedMissionsCompletely() throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let store = try a.createMission()
        let photo = try a.files.save(Data("Foto".utf8), kind: .photo, createdAt: clock.now)
        try store.perform(AddJournalMedia(attachments: [photo], text: ""))

        #expect(throws: MissionPurge.Failure.notDeleted) {
            try MissionPurge.purge(store.missionID, repository: a.repository, files: a.files)
        }
        try store.perform(DeleteMission())
        let removed = try MissionPurge.purge(store.missionID, repository: a.repository, files: a.files)
        #expect(removed == 1)
        #expect(!a.files.isIntact(photo))
        #expect(try a.repository.entity(Mission.self, id: store.missionID.rawValue) == nil)
        #expect(try a.repository.changeEvents(in: store.missionID).isEmpty)
        #expect(try MissionOverview.loadDeleted(from: a.repository).isEmpty)
    }
}
