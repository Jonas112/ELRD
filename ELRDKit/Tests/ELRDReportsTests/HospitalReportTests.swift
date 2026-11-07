import Foundation
import Testing
@testable import ELRDReports
@testable import ELRDDomain
import ELRDStore

@Suite("Bericht für eine Zielklinik (Schritt 56)")
@MainActor
struct HospitalReportTests {
    func input(_ store: MissionStore) -> ReportInput {
        let state = store.state
        return ReportInput(mission: state.mission, patients: state.patients, units: state.units, sections: state.sections,
                           journal: state.journal, log: state.visibleLog, createdBy: "Erika Muster")
    }

    func rowCount(_ blocks: [ReportBlock]) -> Int {
        blocks.compactMap { block -> ReportTable? in
            if case let .table(table) = block { return table }
            return nil
        }.first?.rows.count ?? 0
    }

    @Test func onlyPatientsOfSelectedHospital() throws {
        let store = try PreviewData.makeStore()
        // Vorher gesetzte Zielkliniken der Beispieldaten entfernen.
        for patient in store.state.activePatients where patient.destination != nil {
            try store.perform(SetDestination(patientID: patient.id, hospital: nil))
        }
        let patients = store.state.activePatients
        try #require(patients.count >= 3)
        try store.perform(SetDestination(patientID: patients[0].id, hospital: HospitalSnapshot(name: "Leopoldina", city: "Schweinfurt")))
        try store.perform(SetDestination(patientID: patients[1].id, hospital: HospitalSnapshot(name: " leopoldina ")))
        try store.perform(SetDestination(patientID: patients[2].id, hospital: HospitalSnapshot(name: "Klinikum Würzburg")))

        let destinations = ReportDestination.all(in: store.state.patients)
        #expect(destinations.map(\.name) == ["Leopoldina", "Klinikum Würzburg"], "gleiche Klinik trotz Schreibweise, meiste zuerst")
        #expect(destinations.map(\.patientCount) == [2, 1])

        var options = ReportChapterOptions()
        options.destinationFilter = "LEOPOLDINA"
        let blocks = PatientsChapter.blocks(input(store), options: options, theme: .standard)
        #expect(rowCount(blocks) == 2)
        #expect(blocks.contains { block in
            if case let .paragraph(text, _) = block { return text == "Nur Patienten für: LEOPOLDINA" }
            return false
        })

        options.destinationFilter = "Unbekannte Klinik"
        #expect(rowCount(PatientsChapter.blocks(input(store), options: options, theme: .standard)) == 0)
    }

    @Test func savedOptionsWithoutHospitalStayReadable() throws {
        let old = try JSONDecoder().decode(ReportChapterOptions.self, from: Data(#"{"showsPatientNames":false}"#.utf8))
        #expect(old.destinationFilter == nil)
        #expect(!old.showsPatientNames)
        var options = ReportChapterOptions()
        options.destinationFilter = "Leopoldina"
        let copy = try JSONDecoder().decode(ReportChapterOptions.self, from: JSONEncoder().encode(options))
        #expect(copy.destinationFilter == "Leopoldina")
        #expect(ReportDestination.sameHospital("Leopoldina ", "leopoldina"))
    }
}

@Suite("Klinikbericht an die Klinik (Schritt 62)")
@MainActor
struct HospitalMailTests {
    @Test func emailComesFromAssignedHospital() throws {
        let store = try PreviewData.makeStore()
        let patients = store.state.activePatients
        try #require(patients.count >= 2)
        try store.perform(SetDestination(patientID: patients[0].id, hospital: HospitalSnapshot(name: "Leopoldina", email: " notaufnahme@leopoldina.de ")))
        try store.perform(SetDestination(patientID: patients[1].id, hospital: HospitalSnapshot(name: "St. Josef")))
        #expect(ReportDestination.email(for: "leopoldina", in: store.state.patients) == "notaufnahme@leopoldina.de")
        #expect(ReportDestination.email(for: "St. Josef", in: store.state.patients) == nil, "keine Adresse hinterlegt")
    }
}
