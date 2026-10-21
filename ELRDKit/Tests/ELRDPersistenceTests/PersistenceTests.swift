import Foundation
import SwiftData
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDSync

private enum P {
    static let start = Date(timeIntervalSince1970: 1_792_000_000)
    static let author = UserID()
    static let device = DeviceID()

    static func mission() -> Mission {
        Mission(metadata: .new(by: author, at: start), yearNumber: 3, reason: "VU B19", type: .verkehrsunfall, startedAt: start)
    }

    static func patient(in mission: Mission, number: Int = 1) -> Patient {
        var patient = Patient(
            missionID: mission.id,
            metadata: .new(by: author, at: start),
            number: SerialNumber(prefix: "A", value: number)!,
            triage: .sk2
        )
        patient.lastName = "Muster"
        patient.addInjury(Injury(diagnosis: "Fraktur", region: .arm, side: .links))
        patient.circulation = .instabil
        return patient
    }
}

@Suite("Speicherung – Abbildung")
struct RecordMappingTests {
    @Test func recordColumnsReflectEntity() throws {
        let mission = P.mission()
        var patient = P.patient(in: mission)
        patient.metadata.recordChange(by: P.author, at: P.start.addingTimeInterval(60))
        patient.metadata.markDeleted(by: P.author, at: P.start.addingTimeInterval(120))

        let record = try RecordMapping.makeRecord(patient)
        #expect(record.entityID == patient.id.rawValue)
        #expect(record.entityType == "patient")
        #expect(record.missionID == mission.id.rawValue)
        #expect(record.isSoftDeleted)
        #expect(record.entityVersion == 3)
        #expect(record.updatedAt == P.start.addingTimeInterval(120))
        #expect(record.payloadVersion == RecordMapping.currentPayloadVersion)
        #expect(try RecordMapping.decode(Patient.self, from: record) == patient)
    }

    @Test func missionUsesOwnIDAsMission() throws {
        let mission = P.mission()
        let record = try RecordMapping.makeRecord(mission)
        #expect(record.missionID == mission.id.rawValue)
        #expect(try RecordMapping.decode(Mission.self, from: record) == mission)
    }

    @Test func wrongTypeIsRejected() throws {
        let record = try RecordMapping.makeRecord(P.mission())
        #expect(throws: PersistenceError.typeMismatch(expected: "patient", found: "mission")) {
            try RecordMapping.decode(Patient.self, from: record)
        }
    }

    @Test func newerPayloadIsRejected() throws {
        let record = try RecordMapping.makeRecord(P.mission())
        record.payloadVersion = RecordMapping.currentPayloadVersion + 1
        #expect(throws: PersistenceError.unsupportedPayloadVersion(RecordMapping.currentPayloadVersion + 1)) {
            try RecordMapping.decode(Mission.self, from: record)
        }
    }

    @Test func updateReplacesPayloadAndColumns() throws {
        let mission = P.mission()
        var patient = P.patient(in: mission)
        let record = try RecordMapping.makeRecord(patient)
        patient.triage = .sk1
        patient.metadata.recordChange(by: P.author, at: P.start.addingTimeInterval(30))
        try RecordMapping.update(record, with: patient)
        #expect(record.entityVersion == 2)
        #expect(try RecordMapping.decode(Patient.self, from: record).triage == .sk1)
        #expect(throws: PersistenceError.self) { try RecordMapping.update(record, with: mission) }
    }
}

@Suite("Speicherung – SwiftData")
@MainActor
struct SwiftDataStoreTests {
    @Test func saveAndFetchByMissionAndType() throws {
        let container = try PersistenceStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let mission = P.mission()
        let other = P.mission()
        let patients = [P.patient(in: mission, number: 1), P.patient(in: mission, number: 2), P.patient(in: other, number: 1)]

        context.insert(try RecordMapping.makeRecord(mission))
        for patient in patients { context.insert(try RecordMapping.makeRecord(patient)) }
        try context.save()

        let missionID = mission.id.rawValue
        let type = SyncEntityType.patient.rawValue
        let descriptor = FetchDescriptor<EntityRecord>(
            predicate: #Predicate { $0.missionID == missionID && $0.entityType == type && !$0.isSoftDeleted }
        )
        let loaded = try context.fetch(descriptor).map { try RecordMapping.decode(Patient.self, from: $0) }
        #expect(Set(loaded.map(\.number.description)) == ["A-1", "A-2"])
        let allInMission = loaded.allSatisfy { $0.missionID == mission.id }
        #expect(allInMission)
    }

    @Test func dataSurvivesNewContext() throws {
        let container = try PersistenceStore.makeInMemoryContainer()
        let mission = P.mission()
        do {
            let writer = ModelContext(container)
            writer.insert(try RecordMapping.makeRecord(mission))
            try writer.save()
        }
        let reader = ModelContext(container)
        let id = mission.id.rawValue
        let records = try reader.fetch(FetchDescriptor<EntityRecord>(predicate: #Predicate { $0.entityID == id }))
        #expect(records.count == 1)
        #expect(try RecordMapping.decode(Mission.self, from: records[0]) == mission)
    }

    @Test func changeJournalRoundTripAndOrder() throws {
        let container = try PersistenceStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let mission = P.mission()
        var clock = HybridLogicalClock(deviceID: P.device)

        var events: [ChangeEvent] = []
        let old = P.patient(in: mission)
        var new = old
        let insertEvent = try ChangeRecorder.event(old: nil, new: old, clock: &clock, author: P.author, now: P.start)
        new.triage = .sk1
        let updateEvent = try ChangeRecorder.event(old: old, new: new, clock: &clock, author: P.author, now: P.start)
        events = [insertEvent, updateEvent].compactMap { $0 }
        #expect(events.count == 2)

        // Absichtlich in umgekehrter Reihenfolge speichern.
        for event in events.reversed() { context.insert(try RecordMapping.makeRecord(event)) }
        try context.save()

        let missionID = mission.id.rawValue
        let descriptor = FetchDescriptor<ChangeRecord>(
            predicate: #Predicate { $0.missionID == missionID },
            sortBy: [SortDescriptor(\.wallTime), SortDescriptor(\.counter)]
        )
        let records = try context.fetch(descriptor)
        let allPending = records.allSatisfy { $0.isPendingUpload }
        #expect(allPending)
        let loaded = try records.map(RecordMapping.decode)
        #expect(loaded == events, "Sortierung nach HLC stellt die ursprüngliche Reihenfolge her")
    }

    @Test func fileStoreCanBeCreated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Test.store")

        let mission = P.mission()
        do {
            let container = try PersistenceStore.makeContainer(storeURL: url)
            let context = ModelContext(container)
            context.insert(try RecordMapping.makeRecord(mission))
            try context.save()
        }
        let reopened = try PersistenceStore.makeContainer(storeURL: url)
        let count = try ModelContext(reopened).fetchCount(FetchDescriptor<EntityRecord>())
        #expect(count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
