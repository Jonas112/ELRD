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

@Suite("Abgleich vor Ort zwischen iPads (Schritt 66)")
@MainActor
struct NearbyExchangeTests {
    let server = InMemorySyncServer()
    let clock = TestClock()

    /// Liefert Nachrichten hin und her, bis nichts mehr zu tun ist (wie MultipeerConnectivity).
    func run(_ first: NearbyExchange, _ second: NearbyExchange) throws {
        var queue: [(to: NearbyExchange, message: NearbyMessage, from: NearbyExchange)] = []
        if let message = try first.snapshot() { queue.append((second, message, first)) }
        if let message = try second.snapshot() { queue.append((first, message, second)) }
        var rounds = 0
        while !queue.isEmpty, rounds < 100 {
            rounds += 1
            let next = queue.removeFirst()
            // Über das „Netz“: kodieren und wieder lesen.
            let delivered = try NearbyMessage.decode(next.message.encoded())
            for reply in try next.to.handle(delivered) {
                queue.append((next.from, reply, next.to))
            }
        }
    }

    @Test func secondIPadTakesOverMissionWithPhotos() throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let store = try a.createMission()
        try store.perform(AddPatient(triage: .sk1))
        let photo = try a.files.save(Data("Foto".utf8), kind: .photo, createdAt: clock.now)
        try store.perform(AddJournalMedia(attachments: [photo], text: "Lage"))

        let onA = store.makeNearbyExchange(files: a.files)
        let onB = NearbyExchange(missionID: store.missionID, repository: b.repository, clock: b.deviceClock, files: b.files)
        #expect(try onB.snapshot() == nil, "B kennt den Einsatz noch nicht")
        try run(onA, onB)

        #expect(onB.progress.importedEvents > 0)
        #expect(onB.progress.filesReceived == 1)
        #expect(onA.progress.filesSent == 1)
        #expect(b.files.isIntact(photo))
        #expect(try onB.missingFiles().isEmpty)
        let copy = try b.open(store.missionID)
        #expect(copy.state.activePatients.count == 1)
    }

    @Test func bothSidesExchangeTheirChanges() throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        let onA = storeA.makeNearbyExchange(files: a.files)
        let onB = NearbyExchange(missionID: storeA.missionID, repository: b.repository, clock: b.deviceClock, files: b.files)
        try run(onA, onB)
        let storeB = try b.open(storeA.missionID)

        try storeA.perform(AddJournalText("Von A"))
        try storeB.perform(AddJournalText("Von B"))
        try run(onA, storeB.makeNearbyExchange(files: b.files))
        try storeA.reload()
        try storeB.reload()
        for store in [storeA, storeB] {
            let texts = store.state.journal.active.map(\.text)
            #expect(texts.contains("Von A") && texts.contains("Von B"))
        }
        // Nochmal: nichts Neues.
        let again = storeA.makeNearbyExchange(files: a.files)
        try run(again, storeB.makeNearbyExchange(files: b.files))
        #expect(again.progress.importedEvents == 0)
    }

    @Test func otherMissionIsIgnored() throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let storeA = try a.createMission()
        let storeB = try b.createMission()
        let onB = storeB.makeNearbyExchange(files: b.files)
        let message = try #require(try storeA.makeNearbyExchange(files: a.files).snapshot())
        #expect(try onB.handle(message).isEmpty)
        #expect(onB.progress.importedEvents == 0)
    }
}

@Suite("Abgleich ohne Wettläufe (iCloud-Teilen)")
@MainActor
struct SyncConcurrencyTests {
    let server = InMemorySyncServer()
    let clock = TestClock()

    /// Wartet, bis der Abgleich des Einsatzes begonnen hat.
    private func waitUntilSyncing(_ engine: SyncEngine, _ mission: MissionID) async {
        while !engine.isSyncing(mission) { await Task.yield() }
    }

    @Test func overlappingCallsShareOneFollowUpRun() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let store = try a.createMission()
        await server.setDelay(.milliseconds(80))

        let first = Task { try await a.engine.sync(store.missionID) }
        await waitUntilSyncing(a.engine, store.missionID)
        // Änderung während des ersten Laufs: muss im Folgelauf mitgehen.
        let patient = try store.perform(AddPatient(triage: .sk1))
        let second = Task { try await a.engine.sync(store.missionID) }
        let third = Task { try await a.engine.sync(store.missionID) }

        _ = try await first.value
        let secondReport = try await second.value
        let thirdReport = try await third.value

        #expect(a.engine.completedRuns == 2, "zweiter und dritter Aufruf teilen sich einen Folgelauf")
        #expect(secondReport == thirdReport)
        #expect(secondReport.pushed > 0, "Änderung aus dem laufenden Abgleich nachgereicht")
        #expect(try a.engine.pendingCount(for: store.missionID) == 0)
        let total = try a.repository.changeEvents(in: store.missionID).count
        #expect(await server.eventCount(mission: store.missionID) == total)
        #expect(!a.engine.isSyncing(store.missionID))

        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        try await b.engine.sync(store.missionID)
        #expect(try b.open(store.missionID).state.activePatients.map(\.id) == [patient.id])
    }

    @Test func manyTriggersNeverPushTwiceInParallel() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let store = try a.createMission()
        await server.setDelay(.milliseconds(20))
        var tasks: [Task<SyncReport, any Error>] = []
        for round in 0..<10 {
            if round.isMultiple(of: 3) { try store.perform(AddPatient(triage: .sk2)) }
            tasks.append(Task { try await a.engine.sync(store.missionID) })
            await Task.yield()
        }
        var pushed = 0
        for task in tasks { pushed += try await task.value.pushed }
        let total = try a.repository.changeEvents(in: store.missionID).count
        #expect(await server.eventCount(mission: store.missionID) == total)
        #expect(a.engine.completedRuns <= 10)
        // Jedes Ereignis genau einmal in einem Lauf hochgeladen (geteilte Ergebnisse doppelt gezählt).
        #expect(pushed >= total)
        #expect(try a.engine.pendingCount(for: store.missionID) == 0)
    }

    @Test func pushedStateNeverMovesBackwards() throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let store = try a.createMission()
        clock.advance(5)
        try store.perform(AddPatient(triage: .sk1))
        let own = try a.repository.changeEvents(in: store.missionID).sorted { $0.timestamp < $1.timestamp }
        var checkpoint = SyncCheckpoint()
        checkpoint.advancePushed(to: own.last?.timestamp)
        checkpoint.advancePushed(to: own.first?.timestamp)
        #expect(checkpoint.pushedThrough == own.last?.timestamp, "überholter Lauf setzt nicht zurück")
        checkpoint.advancePushed(to: nil)
        #expect(checkpoint.pushedThrough == own.last?.timestamp)
    }

    @Test func expiredCursorStartsOverWithoutDuplicates() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let store = try a.createMission()
        try await a.engine.sync(store.missionID)
        let first = try await b.engine.sync(store.missionID)
        #expect(first.imported.newEvents > 0)

        let patient = try store.perform(AddPatient(triage: .sk1))
        try await a.engine.sync(store.missionID)

        await server.failNextCall(with: .cursorExpired)
        let again = try await b.engine.sync(store.missionID)
        let added = try a.repository.changeEvents(in: store.missionID).count - first.imported.newEvents
        #expect(again.imported.newEvents == added, "von vorn abgeholt, nur Neues übernommen")
        #expect(try b.open(store.missionID).state.activePatients.map(\.id) == [patient.id])
    }

    @Test func eventsFromFileAreRelayedOnce() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let c = try SyncDevice(prefix: "C", server: server, clock: clock)
        let store = try a.createMission()
        let patient = try store.perform(AddPatient(triage: .sk1))
        // A ist nie online; C bekommt den Einsatz als Datei.
        let archive = try MissionArchive.make(mission: store.missionID, repository: a.repository, files: nil, now: clock.now)
        _ = try archive.importInto(repository: c.repository, clock: c.deviceClock, files: nil)

        let first = try await c.engine.sync(store.missionID)
        #expect(first.relayed == archive.events.count)
        let second = try await c.engine.sync(store.missionID)
        #expect(second.relayed == 0, "nur einmal weiterleiten")

        // D sieht den Einsatz allein über den Server.
        let d = try SyncDevice(prefix: "D", server: server, clock: clock)
        try await d.engine.sync(store.missionID)
        #expect(try d.open(store.missionID).state.activePatients.map(\.id) == [patient.id])

        // Neue Datei mit weiteren fremden Ereignissen → wieder weiterleiten.
        try store.perform(AddPatient(triage: .sk2))
        let newer = try MissionArchive.make(mission: store.missionID, repository: a.repository, files: nil, now: clock.now)
        _ = try newer.importInto(repository: c.repository, clock: c.deviceClock, files: nil)
        let third = try await c.engine.sync(store.missionID)
        #expect(third.relayed > 0)
        try await d.engine.sync(store.missionID)
        #expect(try d.open(store.missionID).state.activePatients.count == 2)
    }

    @Test func receivedFromServerIsNotRelayed() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let b = try SyncDevice(prefix: "B", server: server, clock: clock)
        let store = try a.createMission()
        try store.perform(AddPatient(triage: .sk1))
        try await a.engine.sync(store.missionID)
        try await b.engine.sync(store.missionID)
        let report = try await b.engine.sync(store.missionID)
        #expect(report.relayed == 0)
        #expect(report.pushed == 0)
    }

    @Test func waitUntilIdleCoversQueuedRun() async throws {
        let a = try SyncDevice(prefix: "A", server: server, clock: clock)
        let store = try a.createMission()
        await server.setDelay(.milliseconds(40))
        let first = Task { try await a.engine.sync(store.missionID) }
        await waitUntilSyncing(a.engine, store.missionID)
        let second = Task { try await a.engine.sync(store.missionID) }
        await Task.yield()
        await a.engine.waitUntilIdle(store.missionID)
        #expect(!a.engine.isSyncing(store.missionID))
        _ = try await first.value
        _ = try await second.value
    }
}
