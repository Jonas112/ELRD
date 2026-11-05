import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Patient bearbeiten")
@MainActor
struct PatientCommandTests {
    @Test(arguments: RepositoryKindForStore.allCases)
    func editPatientSavesAndLogsWithoutNames(kind: RepositoryKindForStore) throws {
        let fixture = try StoreFixture(kind: kind)
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk1))

        let updated = try store.perform(EditPatient(patientID: patient.id) {
            $0.firstName = "Thomas"
            $0.lastName = "Mustermann"
            $0.identifyingFeatures = "Fahrer Pkw rot"
        })
        #expect(updated.fullName == "Mustermann, Thomas")
        #expect(updated.metadata.version == 2)
        let message = try #require(store.state.visibleLog.last?.message)
        #expect(message == "Patient A-1: Angaben geändert")
        #expect(!message.contains("Mustermann"), "keine personenbezogenen Daten im Protokoll")

        // Neu geladen identisch (auch das neue Feld wird gespeichert).
        let inMemory = store.state
        try store.reload()
        #expect(store.state == inMemory)
        #expect(store.state.patients.first?.identifyingFeatures == "Fahrer Pkw rot")
    }

    @Test func unchangedEditWritesNothing() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient())
        let events = try store.changeEvents().count
        try store.perform(EditPatient(patientID: patient.id) { $0.notes = "" })
        #expect(try store.changeEvents().count == events)
    }

    @Test func numberChangeIsLoggedWithBothNumbers() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient())
        try store.perform(EditPatient(patientID: patient.id) { $0.number = SerialNumber(prefix: "A", value: 7)! })
        #expect(store.state.visibleLog.last?.message == "Patient A-1: Nummer geändert in A-7")
    }

    @Test func deletedOrClosedCannotBeEdited() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient())
        let other = try store.perform(AddPatient())
        try store.perform(DeletePatient(patientID: patient.id))
        #expect(throws: CommandError.notFound(.patient)) {
            try store.perform(EditPatient(patientID: patient.id) { $0.notes = "x" })
        }
        try store.perform(CloseMission())
        #expect(throws: CommandError.missionClosed) {
            try store.perform(EditPatient(patientID: other.id) { $0.notes = "x" })
        }
    }

    @Test func olderDataWithoutIdentifyingFeaturesStillDecodes() throws {
        let patient = Patient(
            missionID: MissionID(),
            metadata: .new(by: nil, at: Date(timeIntervalSince1970: 0)),
            number: SerialNumber(prefix: "A", value: 1)!,
            identifyingFeatures: "Helm grün"
        )
        let data = try JSONEncoder().encode(patient)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["identifyingFeatures"] as? String == "Helm grün")
        object.removeValue(forKey: "identifyingFeatures")
        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Patient.self, from: older)
        #expect(decoded.identifyingFeatures == nil)
        #expect(decoded.number == patient.number)
    }
}
