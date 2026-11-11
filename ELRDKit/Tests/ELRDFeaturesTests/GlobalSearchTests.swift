import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDStore

@Suite("Globale Suche (Schritt 134)")
@MainActor
struct GlobalSearchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func findsPatientsUnitsAndActions() throws {
        let store = try PreviewData.makeStore(now: now)
        let patient = try store.perform(AddPatient(triage: .sk2))
        try store.perform(EditPatient(patientID: patient.id) { $0.lastName = "Müller"; $0.identifyingFeatures = "rote Jacke" })

        let byName = GlobalSearch.results(for: "muller", in: store.state, canAddPatients: true)
        #expect(byName.contains { $0.kind == .patient(patient.id) }, "ohne Umlaut gefunden")
        let byFeature = GlobalSearch.results(for: "Jacke", in: store.state, canAddPatients: true)
        #expect(byFeature.contains { $0.kind == .patient(patient.id) })

        let empty = GlobalSearch.results(for: "", in: store.state, canAddPatients: true)
        #expect(empty.contains { $0.kind == .area(.map) })
        #expect(empty.contains { $0.kind == .newPatient(.sk1) })
        #expect(!GlobalSearch.results(for: "", in: store.state, canAddPatients: false).contains { $0.kind == .newPatient(.sk1) })

        let action = GlobalSearch.results(for: "bericht", in: store.state, canAddPatients: true)
        #expect(action.contains { $0.kind == .report })
    }
}
