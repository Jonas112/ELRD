import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Zustand und IVENA")
@MainActor
struct ConditionTests {
    static let catalog = RMICatalog(id: "test", name: "Test", entries: [
        RMI(code: 211, title: "Polytrauma mit SHT", category: "Verletzungen/Unfälle - Mehrfach"),
        RMI(code: 212, title: "Polytrauma ohne SHT", category: "Verletzungen/Unfälle - Mehrfach"),
        RMI(code: 121, title: "Schädel-Hirn-Trauma", category: "Verletzungen/Unfälle - Kopf"),
        RMI(code: 312, title: "Herzinfarkt", category: "Kreislauf"),
    ])

    @Test func rmiResultsRankExactNumberFirst() {
        #expect(RMIField.results(in: Self.catalog, for: "212").map(\.code) == [212])
        #expect(RMIField.results(in: Self.catalog, for: "21").map(\.code) == [211, 212])
        #expect(RMIField.results(in: Self.catalog, for: "poly").map(\.code) == [211, 212])
        #expect(RMIField.results(in: Self.catalog, for: "").isEmpty)
        #expect(RMIField.results(in: nil, for: "212").isEmpty)
    }

    @Test func conditionFieldsAreSavedAndKeptWhenPriorityChanges() throws {
        let store = try PreviewData.makeStore()
        let patient = try #require(store.state.activePatients.first)
        try store.perform(EditPatient(patientID: patient.id) {
            $0.circulation = .instabil
            $0.isIntubated = true
            $0.rmiCode = 212
            $0.estimatedAge = 45
            $0.treatmentPriority = .sofortigeIntervention
            $0.abcd = ABCDStatus(airway: 3, breathing: 4, circulation: 3, disability: 4)
            $0.traumaRoom = .a
        })
        var saved = try #require(store.state.patients.first { $0.id == patient.id })
        #expect(saved.allocationCode(at: Date()).description == "212-45-1")
        #expect(saved.abcd?.summary == "A3 B4 C3 D4")
        #expect(saved.medicalSummaryLines.contains("Schockraum A"))

        // Priorität geändert: ABCD bleibt gespeichert (wird nur bei Prio 1 gezeigt).
        try store.perform(EditPatient(patientID: patient.id) { $0.treatmentPriority = .stationaereAufnahmeWahrscheinlich })
        saved = try #require(store.state.patients.first { $0.id == patient.id })
        #expect(saved.allocationCode(at: Date()).description == "212-45-2")
        #expect(saved.abcd != nil)

        // Neu geladen identisch.
        let inMemory = store.state
        try store.reload()
        #expect(store.state == inMemory)
    }
}
