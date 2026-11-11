import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDStore

@Suite("Übungsleiter-Modus (Schritt 138)")
@MainActor
struct ExerciseInjectTests {
    let fixture: StoreFixture

    init() throws {
        fixture = try StoreFixture()
    }

    private func exercise() throws -> MissionStore {
        let scenario = try #require(ExerciseScenario.scenario(id: "bus"))
        var request = NewMissionRequest(reason: scenario.reason, type: scenario.type, location: scenario.location)
        request.scenario = scenario
        let clock = fixture.clock
        return try MissionStore.create(
            request,
            repository: fixture.repository,
            session: fixture.session(fixture.deviceA),
            clock: try DeviceClock(deviceID: fixture.deviceA.deviceID, repository: fixture.repository),
            now: { clock.now }
        )
    }

    @Test func injectsOnlyForExercises() throws {
        let store = try fixture.newMission()
        #expect(throws: CommandError.self) {
            try store.perform(SaveExerciseInject(ExerciseInject(kind: .message, title: "Presse", text: "Reporter")))
        }
    }

    @Test func plannedPatientsInjectReleasesWhenDue() throws {
        let store = try exercise()
        let before = store.state.patients.active.count
        var inject = try #require(ExerciseInject.templates.first { $0.kind == .patients })
        inject.id = UUID()
        inject.minute = 10
        try store.perform(SaveExerciseInject(inject))

        #expect(try store.perform(ReleaseDueExerciseInjects(now: fixture.clock.now)) == 0, "noch nicht fällig")
        fixture.clock.advance(11 * 60)
        #expect(try store.perform(ReleaseDueExerciseInjects(now: fixture.clock.now)) == 1)
        let patients = store.state.patients.active
        #expect(patients.count == before + (inject.patients?.count ?? 0))
        #expect(patients.filter { $0.notes.hasPrefix(ExerciseScore.injectMarker) }.allSatisfy { $0.triage == .ungesichtet && $0.expectedTriage != nil })
        #expect(store.state.mission.exerciseInjects?.first?.isReleased == true)
        #expect(store.state.messages.contains { $0.text.hasPrefix("ÜBUNG – ") })
        #expect(try store.perform(ReleaseDueExerciseInjects(now: fixture.clock.now)) == 0, "nur einmal")
    }

    @Test func hospitalFullAndDeterioration() throws {
        let store = try exercise()
        try store.perform(SetHospitalQuota(HospitalQuota(hospitalName: "Klinikum Test", sk1: 3)))
        let full = ExerciseInject(kind: .hospitalFull, title: "Klinik voll", text: "keine Aufnahme", hospitalName: "Klinikum Test")
        try store.perform(SaveExerciseInject(full))
        try store.perform(ReleaseExerciseInject(full.id))
        let quota = try #require(store.state.mission.hospitalQuotas?.first { $0.hospitalName == "Klinikum Test" })
        #expect(quota.sk1 == 0 && quota.sk2 == 0 && quota.sk3 == 0)

        let sk2 = try #require(store.state.patients.active.first { $0.expectedTriage == .sk2 })
        try store.perform(SetTriage(patientID: sk2.id, triage: .sk2))
        let worse = ExerciseInject(kind: .deterioration, title: "Verschlechterung", text: "trübt ein")
        try store.perform(SaveExerciseInject(worse))
        try store.perform(ReleaseExerciseInject(worse.id))
        #expect(store.state.patients.active.contains { $0.id == sk2.id && $0.expectedTriage == .sk1 })
    }

    @Test func scoreAddsUp() throws {
        let store = try exercise()
        let state = store.state
        let score = try #require(ExerciseScore(mission: state.mission, patients: state.patients, situationReports: 0, now: fixture.clock.now))
        #expect(score.maximum == 85, "ohne Einlagen")
        #expect(score.parts.first { $0.title == "Sichtung" }?.points == 0)
        for patient in store.state.patients.active {
            if let expected = patient.expectedTriage { try store.perform(SetTriage(patientID: patient.id, triage: expected)) }
        }
        let after = try #require(ExerciseScore(mission: store.state.mission, patients: store.state.patients, situationReports: 1, now: fixture.clock.now))
        #expect(after.total == 85, "alles richtig, sofort, Lagemeldung")
        #expect(after.rating == "sehr gut")
    }
}
