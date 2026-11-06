import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Lage-Übersicht: Kennzahlen")
@MainActor
struct SituationDashboardTests {
    @Test func countsTriageTransportAndHospitals() throws {
        let store = try PreviewData.makeStore() // RD 3: 2 RTW, 1 NEF (Platzhalter), 7 Patienten
        let patients = store.state.activePatients
        let rtw = try #require(store.state.activeUnits.first { $0.type == .rtw })
        try store.perform(AssignUnit(patientID: patients[0].id, unitID: rtw.id))
        try store.perform(SetDestination(patientID: patients[0].id, hospital: HospitalSnapshot(name: "LEO Schweinfurt")))
        try store.perform(SetDestination(patientID: patients[1].id, hospital: HospitalSnapshot(name: "LEO Schweinfurt")))
        try store.perform(SetDestination(patientID: patients[2].id, hospital: HospitalSnapshot(name: "Klinikum Coburg")))

        let dashboard = SituationDashboard(state: store.state)
        #expect(dashboard.patientTotal == patients.count)
        #expect(dashboard.triageCounts.values.reduce(0, +) == patients.count)
        #expect(dashboard.unitTotal == 3)
        #expect(dashboard.placeholders == 3)
        #expect(dashboard.busyTransport == 1)
        #expect(dashboard.freeTransport == 1, "NEF zählt nicht als Transportmittel")
        #expect(dashboard.hospitals.map(\.name) == ["LEO Schweinfurt", "Klinikum Coburg"])
        #expect(dashboard.hospitals.first?.total == 2)
    }
}
