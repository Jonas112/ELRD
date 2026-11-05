import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Transport und Entlassung")
@MainActor
struct TransportCommandTests {
    /// Einsatz mit RD 2 (1 RTW, 1 NEF) und zwei Patienten.
    func makeStore() throws -> (StoreFixture, MissionStore, Patient, Patient, MissionUnit, MissionUnit) {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        try store.perform(AddAlarmstichwort(.rd2))
        let first = try store.perform(AddPatient(triage: .sk1))
        let second = try store.perform(AddPatient(triage: .sk2))
        let rtw = try #require(store.state.activeUnits.first { $0.type == .rtw })
        let nef = try #require(store.state.activeUnits.first { $0.type == .nef })
        return (fixture, store, first, second, rtw, nef)
    }

    func patient(_ id: PatientID, in store: MissionStore) throws -> Patient {
        try #require(store.state.patients.first { $0.id == id })
    }

    @Test func assignAndUnassignUnits() throws {
        let (_, store, first, _, rtw, nef) = try makeStore()
        try store.perform(AssignUnit(patientID: first.id, unitID: rtw.id))
        try store.perform(AssignUnit(patientID: first.id, unitID: nef.id))
        try store.perform(AssignUnit(patientID: first.id, unitID: rtw.id)) // doppelt: ohne Wirkung
        #expect(try patient(first.id, in: store).unitIDs == [rtw.id, nef.id])
        #expect(try patient(first.id, in: store).status == .assigned)
        #expect(store.state.visibleLog.last?.message == "Patient A-1: \(nef.displayName) zugeordnet")

        try store.perform(UnassignUnit(patientID: first.id, unitID: nef.id))
        #expect(try patient(first.id, in: store).unitIDs == [rtw.id])
        #expect(throws: CommandError.notFound(.unit)) {
            try store.perform(AssignUnit(patientID: first.id, unitID: UnitID()))
        }
    }

    @Test func transportNeedsUnitAndCanBeUndone() throws {
        let (fixture, store, first, _, rtw, _) = try makeStore()
        #expect(throws: CommandError.invalid("Zuerst eine Einheit zuordnen.")) {
            try store.perform(StartTransport(patientID: first.id))
        }
        try store.perform(AssignUnit(patientID: first.id, unitID: rtw.id))
        try store.perform(SetDestination(patientID: first.id, hospital: HospitalSnapshot(name: "LEO Schweinfurt")))
        fixture.clock.advance(600)
        try store.perform(StartTransport(patientID: first.id))

        let transported = try patient(first.id, in: store)
        #expect(transported.status == .inTransport)
        #expect(transported.outcome == .transported(startedAt: fixture.clock.now))
        #expect(store.state.visibleLog.last?.message == "Patient A-1: Transport mit RTW (Platzhalter 1) nach LEO Schweinfurt")

        try store.perform(ResetOutcome(patientID: first.id))
        #expect(try patient(first.id, in: store).status == .assigned)
    }

    @Test func releaseFreesUnitsAndKeepsTheirNames() throws {
        let (_, store, first, _, rtw, _) = try makeStore()
        try store.perform(AssignUnit(patientID: first.id, unitID: rtw.id))
        try store.perform(SetDestination(patientID: first.id, hospital: HospitalSnapshot(name: "LEO Schweinfurt")))
        try store.perform(ReleasePatient(patientID: first.id, clearDestination: true))

        let released = try patient(first.id, in: store)
        #expect(released.status == .released)
        #expect(released.unitIDs.isEmpty)
        #expect(released.destination == nil)
        if case let .released(_, handledBy) = released.outcome {
            #expect(handledBy == ["RTW (Platzhalter 1)"])
        } else {
            Issue.record("Patient sollte entlassen sein")
        }
        #expect(rtw.isFree(in: store.state.patients))
        #expect(throws: CommandError.invalid("Der Patient ist entlassen.")) {
            try store.perform(AssignUnit(patientID: first.id, unitID: rtw.id))
        }
    }

    @Test func changingDestinationRestartsRegistration() throws {
        let (_, store, first, _, _, _) = try makeStore()
        try store.perform(SetDestination(patientID: first.id, hospital: HospitalSnapshot(name: "LEO Schweinfurt")))
        try store.perform(SetRegistration(patientID: first.id, state: .angemeldet))
        #expect(try patient(first.id, in: store).registrationState == .angemeldet)
        try store.perform(SetDestination(patientID: first.id, hospital: HospitalSnapshot(name: "KHS St. Josef")))
        #expect(try patient(first.id, in: store).registrationState == .unklar)

        // Neu geladen identisch.
        let inMemory = store.state
        try store.reload()
        #expect(store.state == inMemory)
    }
}
