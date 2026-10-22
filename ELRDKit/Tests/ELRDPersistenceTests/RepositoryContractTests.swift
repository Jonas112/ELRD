import Foundation
import SwiftData
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDSync

/// Beide Repository-Arten müssen sich identisch verhalten.
enum RepositoryKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case swiftData
    case inMemory

    var testDescription: String { rawValue }

    @MainActor
    func make() throws -> any EntityRepository {
        switch self {
        case .swiftData: SwiftDataRepository(container: try PersistenceStore.makeInMemoryContainer())
        case .inMemory: InMemoryRepository()
        }
    }
}

private enum R {
    static let start = Date(timeIntervalSince1970: 1_792_000_000)
    static let author = UserID()
    static let deviceA = DeviceID()
    static let deviceB = DeviceID()

    static func mission(_ yearNumber: Int, hoursLater: Double = 0) -> Mission {
        let started = start.addingTimeInterval(hoursLater * 3600)
        return Mission(metadata: .new(by: author, at: started), yearNumber: yearNumber, startedAt: started)
    }

    static func patient(_ mission: Mission, _ number: Int) -> Patient {
        Patient(missionID: mission.id, metadata: .new(by: author, at: start), number: SerialNumber(prefix: "A", value: number)!)
    }

    static func unit(_ mission: Mission) -> MissionUnit {
        MissionUnit(missionID: mission.id, metadata: .new(by: author, at: start), type: .rtw, callsign: "RTW 1")
    }

    static func changeSet(_ build: (inout ChangeSet) throws -> Void) rethrows -> ChangeSet {
        var set = ChangeSet()
        try build(&set)
        return set
    }

    static func event(_ mission: Mission, wall: Int64, counter: Int = 0, device: DeviceID = deviceA) -> ChangeEvent {
        ChangeEvent(
            missionID: mission.id,
            entityType: .mission,
            entityID: mission.id.rawValue,
            operation: .update,
            changes: [.set(field: "reason", value: .string("Test \(wall)"))],
            timestamp: HybridTimestamp(wallTime: wall, counter: counter, deviceID: device),
            authorID: author
        )
    }
}

@Suite("Repository – Vertrag")
@MainActor
struct RepositoryContractTests {
    @Test(arguments: RepositoryKind.allCases)
    func storeAndQueryByMissionAndType(kind: RepositoryKind) throws {
        let repo = try kind.make()
        let mission = R.mission(1)
        let other = R.mission(2)
        var deleted = R.patient(mission, 3)
        deleted.metadata.markDeleted(by: R.author, at: R.start)

        try repo.apply(R.changeSet { set in
            try set.upsert(mission)
            try set.upsert(other)
            try set.upsert(R.patient(mission, 1))
            try set.upsert(R.patient(mission, 2))
            try set.upsert(deleted)
            try set.upsert(R.patient(other, 1))
            try set.upsert(R.unit(mission))
        })

        let active = try repo.entities(Patient.self, in: mission.id)
        #expect(Set(active.map(\.number.description)) == ["A-1", "A-2"])
        let all = try repo.entities(Patient.self, in: mission.id, includeDeleted: true)
        #expect(all.count == 3)
        #expect(try repo.entities(MissionUnit.self, in: mission.id).count == 1)
        #expect(try repo.entity(Mission.self, id: mission.id) == mission)
        #expect(try repo.entity(Patient.self, id: deleted.id)?.isDeleted == true)
        #expect(try repo.entity(Patient.self, id: UUID()) == nil)
    }

    @Test(arguments: RepositoryKind.allCases)
    func missionsNewestFirstWithoutDeleted(kind: RepositoryKind) throws {
        let repo = try kind.make()
        let older = R.mission(1)
        let newer = R.mission(2, hoursLater: 5)
        var removed = R.mission(3, hoursLater: 10)
        removed.metadata.markDeleted(by: R.author, at: R.start)
        try repo.apply(R.changeSet { set in
            try set.upsert(older)
            try set.upsert(newer)
            try set.upsert(removed)
        })
        #expect(try repo.missions().map(\.yearNumber) == [2, 1])
        #expect(try repo.missions(includeDeleted: true).map(\.yearNumber) == [3, 2, 1])
    }

    @Test(arguments: RepositoryKind.allCases)
    func updateRequiresNewerVersion(kind: RepositoryKind) throws {
        let repo = try kind.make()
        let mission = R.mission(1)
        try repo.apply(R.changeSet { try $0.upsert(mission) })

        // Zweites Fenster ändert den Einsatz und speichert zuerst.
        var windowA = mission
        windowA.reason = "Fenster A"
        windowA.metadata.recordChange(by: R.author, at: R.start.addingTimeInterval(10))
        try repo.apply(R.changeSet { try $0.upsert(windowA) })

        // Erstes Fenster speichert danach seinen älteren Stand mit gleicher Version.
        var windowB = mission
        windowB.reason = "Fenster B"
        windowB.metadata.recordChange(by: R.author, at: R.start.addingTimeInterval(20))
        #expect(throws: PersistenceError.self) {
            try repo.apply(R.changeSet { try $0.upsert(windowB) })
        }
        #expect(try repo.entity(Mission.self, id: mission.id)?.reason == "Fenster A")

        // Erneutes Speichern desselben Stands ist erlaubt.
        try repo.apply(R.changeSet { try $0.upsert(windowA) })
    }

    @Test(arguments: RepositoryKind.allCases)
    func failedChangeSetWritesNothing(kind: RepositoryKind) throws {
        let repo = try kind.make()
        let mission = R.mission(1)
        try repo.apply(R.changeSet { try $0.upsert(mission) })

        let newPatient = R.patient(mission, 1)
        var stale = mission
        stale.reason = "veraltet"
        #expect(throws: PersistenceError.self) {
            try repo.apply(R.changeSet { set in
                try set.upsert(newPatient)
                try set.upsert(stale)
                set.record(R.event(mission, wall: 1))
            })
        }
        #expect(try repo.entity(Patient.self, id: newPatient.id) == nil)
        #expect(try repo.changeEvents(in: mission.id).isEmpty)
    }

    @Test(arguments: RepositoryKind.allCases)
    func typeMismatchIsReported(kind: RepositoryKind) throws {
        let repo = try kind.make()
        let mission = R.mission(1)
        try repo.apply(R.changeSet { try $0.upsert(mission) })
        #expect(throws: PersistenceError.self) {
            _ = try repo.entity(Patient.self, id: mission.id.rawValue)
        }
    }

    @Test(arguments: RepositoryKind.allCases)
    func eventsAreStoredOnceInClockOrder(kind: RepositoryKind) throws {
        let repo = try kind.make()
        let mission = R.mission(1)
        let late = R.event(mission, wall: 300)
        let early = R.event(mission, wall: 100, device: R.deviceB)
        let middle = R.event(mission, wall: 200, counter: 1)

        try repo.apply(R.changeSet { set in
            set.record(late)
            set.record(early)
        })
        try repo.apply(R.changeSet { set in
            set.record(late)
            set.record(middle)
        })

        #expect(try repo.changeEvents(in: mission.id).map(\.id) == [early.id, middle.id, late.id])
        #expect(try repo.latestTimestamp(of: R.deviceA) == late.timestamp)
        #expect(try repo.latestTimestamp(of: R.deviceB) == early.timestamp)
        #expect(try repo.latestTimestamp(of: DeviceID()) == nil)
    }

    @Test(arguments: RepositoryKind.allCases)
    func purgeRemovesOnlyThatMission(kind: RepositoryKind) throws {
        let repo = try kind.make()
        let purged = R.mission(1)
        let kept = R.mission(2)
        try repo.apply(R.changeSet { set in
            try set.upsert(purged)
            try set.upsert(kept)
            try set.upsert(R.patient(purged, 1))
            try set.upsert(R.patient(kept, 1))
            set.record(R.event(purged, wall: 1))
            set.record(R.event(kept, wall: 2))
        })

        try repo.purgeMission(purged.id)

        #expect(try repo.missions(includeDeleted: true).map(\.id) == [kept.id])
        #expect(try repo.entities(Patient.self, in: purged.id, includeDeleted: true).isEmpty)
        #expect(try repo.changeEvents(in: purged.id).isEmpty)
        #expect(try repo.entities(Patient.self, in: kept.id).count == 1)
        #expect(try repo.changeEvents(in: kept.id).count == 1)
    }

    @Test func changeSetKeepsLatestUpsertPerEntity() throws {
        let mission = R.mission(1)
        var changed = mission
        changed.reason = "neu"
        var set = ChangeSet()
        try set.upsert(mission)
        try set.upsert(changed)
        let event = R.event(mission, wall: 1)
        set.record(event)
        set.record(event)
        #expect(set.snapshots.count == 1)
        #expect(set.events.count == 1)
        #expect(try set.snapshots[0].decode(Mission.self).reason == "neu")
    }

    @Test func inMemoryFailureLeavesStateUntouched() throws {
        let repo = InMemoryRepository()
        let mission = R.mission(1)
        repo.failNextApply = true
        #expect(throws: InMemoryRepositoryError.self) {
            try repo.apply(R.changeSet { try $0.upsert(mission) })
        }
        #expect(try repo.missions().isEmpty)
    }

    @Test func swiftDataSharesStoreAcrossRepositories() throws {
        let container = try PersistenceStore.makeInMemoryContainer()
        let mission = R.mission(1)
        try SwiftDataRepository(container: container).apply(R.changeSet { try $0.upsert(mission) })
        #expect(try SwiftDataRepository(container: container).missions() == [mission])
    }
}
