import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDFeatures
import ELRDStore

@Suite("Abschnittsübersicht")
@MainActor
struct SectionBoardTests {
    @Test func columnsGroupUnitsAndPatients() throws {
        let store = try PreviewData.makeStore() // 3 Abschnitte, RD 3 im Bereitstellungsraum
        let sections = store.state.activeSections
        let patients = store.state.activePatients
        let rtw = try #require(store.state.activeUnits.first { $0.type == .rtw })
        try store.perform(AssignUnit(patientID: patients[0].id, unitID: rtw.id))
        try store.perform(MoveUnit(unitID: rtw.id, to: nil))
        try store.perform(EditPatient(patientID: patients[1].id) { $0.sectionID = sections[1].id })

        let columns = SectionColumn.columns(for: store.state)
        #expect(columns.map(\.title) == ["Ohne Abschnitt", "Bereitstellungsraum", "Patientenablage", "Behandlungsplatz"])
        #expect(columns[0].units.map(\.unit.id) == [rtw.id])
        #expect(columns[0].units[0].patients.map(\.number) == ["A-1"])
        #expect(columns[1].isInitial)
        #expect(columns[1].typeSummary == "1 RTW · 1 NEF")
        #expect(columns[2].loosePatients.map(\.number) == ["A-2"], "Patient ohne Einheit im Abschnitt")
        #expect(columns[3].units.isEmpty && columns[3].typeSummary.isEmpty)
    }

    @Test func noHomelessColumnWhenAllPlaced() throws {
        let store = try PreviewData.makeStore()
        #expect(SectionColumn.columns(for: store.state).first?.title == "Bereitstellungsraum")
    }

    @Test func templatesAreSavedAndOfferedOnce() throws {
        let repository = InMemoryRepository()
        try repository.saveDocument(MasterDataSet(), key: .masterData, at: Date())
        let templates = SectionTemplates(repository: repository)
        try templates.save("Patientenablage")
        try templates.save("patientenablage")
        #expect(templates.sections.map(\.name) == ["Patientenablage"])
        #expect(templates.contains(" Patientenablage "))
        #expect(try repository.document(MasterDataSet.self, key: .masterData)?.sections.count == 1)

        let store = try PreviewData.makeStore() // enthält „Patientenablage“
        #expect(templates.unused(in: store.state.sections).isEmpty, "schon im Einsatz")
        #expect(SectionTemplates(repository: repository).sections.count == 1, "dauerhaft gespeichert")
    }
}
