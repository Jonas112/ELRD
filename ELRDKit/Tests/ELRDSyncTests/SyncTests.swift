import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDSync

private enum S {
    static let start = Date(timeIntervalSince1970: 1_792_000_000)
    static let missionID = MissionID()
    static let deviceA = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    static let deviceB = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
    static let userA = UserID()
    static let userB = UserID()

    static func patient() -> Patient {
        Patient(
            missionID: missionID,
            metadata: .new(by: userA, at: start),
            number: SerialNumber(prefix: "A", value: 1)!,
            triage: .ungesichtet
        )
    }

    static func ts(_ seconds: Double, _ counter: Int = 0, device: DeviceID = deviceA) -> HybridTimestamp {
        HybridTimestamp(wallTime: Int64((start.timeIntervalSince1970 + seconds) * 1000), counter: counter, deviceID: device)
    }
}

@Suite("Hybrid Logical Clock")
struct HybridLogicalClockTests {
    @Test func tickIsStrictlyMonotonic() {
        var clock = HybridLogicalClock(deviceID: S.deviceA)
        let first = clock.tick(now: S.start)
        let sameMillisecond = clock.tick(now: S.start)
        let clockWentBack = clock.tick(now: S.start.addingTimeInterval(-10))
        let later = clock.tick(now: S.start.addingTimeInterval(1))
        #expect(first < sameMillisecond)
        #expect(sameMillisecond < clockWentBack)
        #expect(clockWentBack < later)
        #expect(later.counter == 0)
    }

    @Test func receiveMovesPastRemote() throws {
        var clock = HybridLogicalClock(deviceID: S.deviceA)
        _ = clock.tick(now: S.start)
        let remote = S.ts(30, 4, device: S.deviceB)
        let merged = try clock.receive(remote, now: S.start.addingTimeInterval(1))
        #expect(merged > remote)
        #expect(merged.wallTime == remote.wallTime)
        #expect(merged.counter == 5)
        #expect(clock.tick(now: S.start.addingTimeInterval(2)) > merged)
    }

    @Test func rejectsRemoteClockFarAhead() {
        var clock = HybridLogicalClock(deviceID: S.deviceA, maximumDrift: 60)
        #expect(throws: HybridClockError.self) {
            try clock.receive(S.ts(3600, device: S.deviceB), now: S.start)
        }
        #expect(clock.last == nil, "Abgelehnter Zeitstempel wird nicht übernommen")
    }

    @Test func tieBreakByDevice() {
        #expect(S.ts(0, 0, device: S.deviceA) < S.ts(0, 0, device: S.deviceB))
        #expect(S.ts(0, 1, device: S.deviceA) > S.ts(0, 0, device: S.deviceB))
    }
}

@Suite("Änderungen erfassen")
struct ChangeRecorderTests {
    @Test func insertContainsAllFieldsButNoMetadata() throws {
        var clock = HybridLogicalClock(deviceID: S.deviceA)
        var patient = S.patient()
        patient.addInjury(Injury(diagnosis: "Fraktur", region: .arm, side: .links))
        let eventResult = try ChangeRecorder.event(old: nil, new: patient, clock: &clock, author: S.userA, now: S.start)
        let event = try #require(eventResult)
        #expect(event.operation == .insert)
        #expect(event.entityType == .patient)
        #expect(event.entityID == patient.id.rawValue)
        #expect(event.missionID == S.missionID)
        #expect(!event.changes.contains { $0.field == "metadata" })
        #expect(event.changes.contains(.set(field: "triage", value: .number(5))))
        #expect(event.changes.contains(.set(field: "number", value: .string("A-1"))))
        #expect(event.changes.contains { if case .upsertElement("injuries", _, _) = $0 { true } else { false } })
    }

    @Test func noEventWithoutChanges() throws {
        var clock = HybridLogicalClock(deviceID: S.deviceA)
        let patient = S.patient()
        var touched = patient
        touched.metadata.recordChange(by: S.userB, at: S.start.addingTimeInterval(5))
        let event = try ChangeRecorder.event(old: patient, new: touched, clock: &clock, author: S.userB, now: S.start)
        #expect(event == nil)
    }

    @Test func updateRecordsOnlyChangedFields() throws {
        let old = S.patient()
        var new = old
        new.triage = .sk1
        new.assign(unit: UnitID())
        let changes = try ChangeRecorder.diff(old: old, new: new)
        #expect(changes.count == 2)
        #expect(changes.contains(.set(field: "triage", value: .number(1))))
        #expect(changes.contains { if case .upsertElement("unitIDs", _, _) = $0 { true } else { false } })
    }

    @Test func removingListElement() throws {
        let unit = UnitID()
        var old = S.patient()
        old.assign(unit: unit)
        var new = old
        new.unassign(unit: unit)
        let changes = try ChangeRecorder.diff(old: old, new: new)
        #expect(changes == [.removeElement(field: "unitIDs", elementID: unit.rawValue.uuidString)])
    }

    @Test func deleteAndRestoreOperations() throws {
        var clock = HybridLogicalClock(deviceID: S.deviceA)
        let patient = S.patient()
        var deleted = patient
        deleted.metadata.markDeleted(by: S.userA, at: S.start)
        let deleteEvent = try ChangeRecorder.event(old: patient, new: deleted, clock: &clock, author: S.userA, now: S.start)
        #expect(deleteEvent?.operation == .delete)
        let restoreEvent = try ChangeRecorder.event(old: deleted, new: patient, clock: &clock, author: S.userA, now: S.start)
        #expect(restoreEvent?.operation == .restore)
    }
}

@Suite("Änderungen zusammenführen")
struct ChangeMergerTests {
    /// Ereignisse zweier Geräte, die unabhängig voneinander denselben Patienten bearbeiten.
    func concurrentEvents() throws -> (base: Patient, events: [ChangeEvent]) {
        let base = S.patient()
        var clockA = HybridLogicalClock(deviceID: S.deviceA)
        var clockB = HybridLogicalClock(deviceID: S.deviceB)
        let insertResult = try ChangeRecorder.event(old: nil, new: base, clock: &clockA, author: S.userA, now: S.start)
        let insert = try #require(insertResult)
        try clockB.receive(insert.timestamp, now: S.start)

        // Gerät A: Sichtung SK 1 und Verletzung
        var onA = base
        onA.triage = .sk1
        onA.addInjury(Injury(diagnosis: "Fraktur", region: .unterschenkel, side: .rechts))
        let eventAResult = try ChangeRecorder.event(old: base, new: onA, clock: &clockA, author: S.userA, now: S.start.addingTimeInterval(10))
        let eventA = try #require(eventAResult)

        // Gerät B gleichzeitig: Name, andere Verletzung, Sichtung SK 2 (etwas später)
        var onB = base
        onB.lastName = "Muster"
        onB.triage = .sk2
        onB.addInjury(Injury(diagnosis: "Prellung", region: .thorax))
        let eventBResult = try ChangeRecorder.event(old: base, new: onB, clock: &clockB, author: S.userB, now: S.start.addingTimeInterval(11))
        let eventB = try #require(eventBResult)

        return (base, [insert, eventA, eventB])
    }

    func merged(_ events: [ChangeEvent]) -> MergeState {
        var state = MergeState()
        for event in events { state.apply(event) }
        return state
    }

    @Test func concurrentChangesAreCombined() throws {
        let (base, events) = try concurrentEvents()
        let state = merged(events)
        let patient = try state.decode(Patient.self, metadata: JSONValueCoder.encode(base.metadata))
        #expect(patient.lastName == "Muster", "Änderung von Gerät B bleibt erhalten")
        #expect(patient.triage == .sk2, "Gleiches Feld: spätere Änderung gewinnt")
        #expect(Set(patient.injuries.map(\.diagnosis)) == ["Fraktur", "Prellung"], "Beide Verletzungen bleiben erhalten")
    }

    @Test func orderOfArrivalDoesNotMatter() throws {
        let (_, events) = try concurrentEvents()
        let reference = merged(events).fields
        for permutation in permutations(events) {
            #expect(merged(permutation).fields == reference)
        }
    }

    @Test func duplicateDeliveryIsHarmless() throws {
        let (_, events) = try concurrentEvents()
        #expect(merged(events + events.reversed()).fields == merged(events).fields)
    }

    @Test func roundTripReproducesEntity() throws {
        var clock = HybridLogicalClock(deviceID: S.deviceA)
        var patient = S.patient()
        patient.firstName = "Max"
        patient.birthDate = S.start.addingTimeInterval(-40 * 365 * 86_400)
        patient.addInjury(Injury(diagnosis: "SHT", region: .kopf))
        patient.assign(unit: UnitID())
        patient.setDestination(HospitalSnapshot(name: "Klinikum", city: "Musterstadt"))
        patient.startTransport(at: S.start)
        let eventResult = try ChangeRecorder.event(old: nil, new: patient, clock: &clock, author: S.userA, now: S.start)
        let event = try #require(eventResult)
        let decoded = try merged([event]).decode(Patient.self, metadata: JSONValueCoder.encode(patient.metadata))
        #expect(decoded == patient)
    }

    @Test func newerRemovalBeatsOlderInsert() {
        let element = JSONValue.string("X")
        var state = MergeState()
        state.apply(.removeElement(field: "unitIDs", elementID: "X"), at: S.ts(2))
        state.apply(.upsertElement(field: "unitIDs", elementID: "X", value: element), at: S.ts(1))
        #expect(state.fields["unitIDs"] == nil || state.fields["unitIDs"] == .array([]))

        var reAdded = state
        reAdded.apply(.upsertElement(field: "unitIDs", elementID: "X", value: element), at: S.ts(3))
        #expect(reAdded.fields["unitIDs"] == .array([element]))
    }

    @Test func emptyListFromInsertDoesNotWipeLaterElements() {
        var state = MergeState()
        state.apply(.upsertElement(field: "unitIDs", elementID: "X", value: .string("X")), at: S.ts(2))
        state.apply(.set(field: "unitIDs", value: .array([])), at: S.ts(1))
        #expect(state.fields["unitIDs"] == .array([.string("X")]))
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let item = rest.remove(at: index)
            return permutations(rest).map { [item] + $0 }
        }
    }
}

@Suite("Entitätsverlauf und Server-Vertrag (Schritt 53)")
struct EntityHistoryTests {
    private func lifecycle(_ operation: ChangeOperation, at seconds: Double, device: DeviceID = S.deviceA, author: UserID? = S.userA) -> ChangeEvent {
        ChangeEvent(missionID: S.missionID, entityType: .patient, entityID: entityID, operation: operation,
                    changes: [], timestamp: S.ts(seconds, device: device), authorID: author)
    }

    private let entityID = UUID()

    @Test func latestLifecycleEventDecidesDeletion() {
        let insert = lifecycle(.insert, at: 0)
        let delete = lifecycle(.delete, at: 10, device: S.deviceB)
        let lateEdit = ChangeEvent(missionID: S.missionID, entityType: .patient, entityID: entityID, operation: .update,
                                   changes: [.set(field: "lastName", value: .string("Neu"))], timestamp: S.ts(20), authorID: S.userA)
        #expect(EntityHistory([insert, delete, lateEdit]).isDeleted, "Bearbeiten hebt Löschen nicht auf")
        #expect(EntityHistory([lateEdit, delete, insert]).isDeleted, "Reihenfolge egal")
        let restore = lifecycle(.restore, at: 15)
        #expect(!EntityHistory([delete, restore, insert, lateEdit]).isDeleted)
        let deleteAgain = lifecycle(.delete, at: 30, device: S.deviceB)
        #expect(EntityHistory([insert, delete, restore, deleteAgain]).isDeleted)
    }

    @Test func metadataComesFromEvents() throws {
        let insert = lifecycle(.insert, at: 0)
        let delete = lifecycle(.delete, at: 10, device: S.deviceB, author: S.userB)
        let history = EntityHistory([delete, insert, insert])
        #expect(history.events.count == 2, "doppelte Ereignisse zählen einmal")
        let metadata = try #require(history.metadata())
        #expect(metadata.createdBy == S.userA)
        #expect(metadata.createdAt == S.start)
        #expect(metadata.updatedBy == S.userB)
        #expect(metadata.deletedAt == S.start.addingTimeInterval(10))
        #expect(metadata.version == 2)
        #expect(EntityHistory([delete]).metadata() == nil, "ohne Anlegen kein Stand")
    }

    @Test func mergedEntityMatchesRecordedPatient() throws {
        var clock = HybridLogicalClock(deviceID: S.deviceA)
        var patient = S.patient()
        patient.firstName = "Max"
        let insertResult = try ChangeRecorder.event(old: nil, new: patient, clock: &clock, author: S.userA, now: S.start)
        let insert = try #require(insertResult)
        var edited = patient
        edited.triage = .sk1
        edited.metadata.recordChange(by: S.userA, at: S.start.addingTimeInterval(5))
        let editResult = try ChangeRecorder.event(old: patient, new: edited, clock: &clock, author: S.userA, now: S.start.addingTimeInterval(5))
        let edit = try #require(editResult)
        let merged = try #require(try EntityHistory([edit, insert]).entity(Patient.self))
        #expect(merged.firstName == "Max")
        #expect(merged.triage == .sk1)
        #expect(merged.metadata.version == 2)
        #expect(!merged.isDeleted)
    }

    @Test func serverIsIdempotentAndPaged() async throws {
        let server = InMemorySyncServer()
        let events = (0..<5).map { lifecycle(.insert, at: Double($0)) }
        try await server.push(events, mission: S.missionID)
        try await server.push(events, mission: S.missionID)
        #expect(await server.eventCount(mission: S.missionID) == 5)

        let first = try await server.pull(mission: S.missionID, after: nil, limit: 3)
        #expect(first.events.count == 3)
        #expect(first.hasMore)
        let second = try await server.pull(mission: S.missionID, after: first.cursor, limit: 3)
        #expect(second.events.count == 2)
        #expect(!second.hasMore)
        let empty = try await server.pull(mission: S.missionID, after: second.cursor, limit: 3)
        #expect(empty.events.isEmpty)

        try await server.purge(mission: S.missionID)
        #expect(await server.eventCount(mission: S.missionID) == 0)
    }

    @Test func outboxOnlyContainsOwnUnsentEvents() {
        let own = [lifecycle(.insert, at: 0), lifecycle(.update, at: 5), lifecycle(.update, at: 9)]
        let foreign = lifecycle(.update, at: 7, device: S.deviceB)
        var checkpoint = SyncCheckpoint()
        #expect(checkpoint.outbox(own + [foreign], device: S.deviceA).count == 3)
        checkpoint.pushedThrough = own[1].timestamp
        #expect(checkpoint.outbox(own + [foreign], device: S.deviceA) == [own[2]])

        var all = SyncCheckpoints()
        all[S.missionID] = checkpoint
        #expect(all[S.missionID] == checkpoint)
        all.remove(S.missionID)
        #expect(all[S.missionID] == SyncCheckpoint())
    }
}
