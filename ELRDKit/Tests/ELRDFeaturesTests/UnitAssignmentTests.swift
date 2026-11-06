import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStammdaten
@testable import ELRDFeatures
import ELRDStore

@Suite("Patient: Einheitenwahl und Region laden")
@MainActor
struct UnitAssignmentTests {
    @Test func choicesAreGroupedByTransportAndState() throws {
        let store = try PreviewData.makeStore() // RD 3: 2 RTW, 1 NEF (Platzhalter)
        let patients = store.state.activePatients
        let rtws = store.state.activeUnits.filter { $0.type == .rtw }
        try store.perform(AssignUnit(patientID: patients[0].id, unitID: rtws[0].id))
        try store.perform(AssignUnit(patientID: patients[1].id, unitID: rtws[1].id))

        let choices = UnitChoice.ordered(units: store.state.units, patients: store.state.patients, for: patients[0].id)
        let groups = UnitAssignmentGroups(choices)
        #expect(groups.assigned.map(\.id) == [rtws[0].id])
        #expect(groups.freeTransport.isEmpty, "der zweite RTW ist belegt")
        #expect(groups.freeOther.map(\.unit.type) == [.nef], "NEF transportiert nicht")
        #expect(groups.busy.map(\.id) == [rtws[1].id])
        #expect(groups.busy.first?.otherPatients == [patients[1].number.description])
    }

    @Test func regionImportFillsUnitsAndHospitals() throws {
        let repository = InMemoryRepository()
        try repository.saveDocument(MasterDataSet(), key: .masterData, at: Date())
        let editor = MasterDataEditor(repository: repository)
        #expect(editor.units.isEmpty)
        let region = try #require(BundledMasterData.region(id: "schweinfurt"))
        let report = try editor.importRegion(region)
        #expect(report.unitsAdded > 0)
        #expect(report.hospitalsAdded > 0)
        #expect(!editor.units.isEmpty)
        #expect(editor.loadedRegionIDs.contains("schweinfurt"))
        #expect(editor.revision == 1)
        let again = try editor.importRegion(region)
        #expect(again.unitsAdded == 0, "doppelte übersprungen")
    }
}
