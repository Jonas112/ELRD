import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Abschnitte")
@MainActor
struct SectionCommandTests {
    @Test func firstSectionBecomesInitialAndNewUnitsGoThere() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission(sections: [])
        let first = try store.perform(AddSection(name: "  Bereitstellungsraum "))
        #expect(first.name == "Bereitstellungsraum")
        #expect(first.isInitial, "ohne Initialabschnitt wird der erste einer (E68)")
        let second = try store.perform(AddSection(name: "Patientenablage"))
        #expect(!second.isInitial)
        #expect(second.sortIndex > first.sortIndex)

        let units = try store.perform(AddAlarmstichwort(.rd2))
        #expect(units.allSatisfy { $0.sectionID == first.id })
        #expect(store.state.visibleLog.last?.message.hasPrefix("Alarmstichwort") == true)
    }

    @Test func explicitInitialReplacesAndCanBeSwitchedOff() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission(sections: [])
        let first = try store.perform(AddSection(name: "A", makeInitial: false))
        #expect(!first.isInitial, "ausdrücklich nicht")
        let second = try store.perform(AddSection(name: "B", makeInitial: true))
        #expect(second.isInitial)
        try store.perform(SetInitialSection(sectionID: first.id))
        #expect(store.state.activeSections.filter(\.isInitial).map(\.id) == [first.id], "höchstens einer")
        try store.perform(SetInitialSection(sectionID: nil))
        #expect(store.state.activeSections.allSatisfy { !$0.isInitial })
        #expect(store.state.visibleLog.last?.message == "Kein Initialabschnitt mehr")
    }

    @Test func renameAndMoveUnit() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission() // Bereitstellungsraum (initial), Patientenablage
        let sections = store.state.activeSections
        let units = try store.perform(AddAlarmstichwort(.rd1))
        let rtw = try #require(units.first)
        try store.perform(MoveUnit(unitID: rtw.id, to: sections[1].id))
        #expect(store.state.units.first { $0.id == rtw.id }?.sectionID == sections[1].id)
        #expect(store.state.visibleLog.last?.message == "\(rtw.displayName) → „Patientenablage“")
        try store.perform(MoveUnit(unitID: rtw.id, to: nil))
        #expect(store.state.units.first { $0.id == rtw.id }?.sectionID == nil)

        try store.perform(RenameSection(sectionID: sections[1].id, name: "Behandlungsplatz"))
        #expect(store.state.activeSections[1].name == "Behandlungsplatz")
        #expect(store.state.visibleLog.last?.message == "Abschnitt „Patientenablage“ umbenannt in „Behandlungsplatz“")
        #expect(throws: CommandError.notFound(.section)) {
            try store.perform(MoveUnit(unitID: rtw.id, to: SectionID()))
        }
    }

    @Test func deleteKeepsUnitsAndPatients() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let initial = try #require(store.state.activeSections.first)
        let units = try store.perform(AddAlarmstichwort(.rd2))
        let patient = try store.perform(AddPatient(triage: .sk2, sectionID: initial.id))

        try store.perform(DeleteSection(sectionID: initial.id))
        #expect(store.state.activeSections.map(\.name) == ["Patientenablage"])
        #expect(store.state.activeUnits.count == units.count, "Einheiten bleiben erhalten")
        #expect(store.state.activeUnits.allSatisfy { $0.sectionID == nil })
        #expect(store.state.patients.first { $0.id == patient.id }?.sectionID == nil)
        #expect(MissionSection.initialSection(in: store.state.sections) == nil)
        #expect(store.state.visibleLog.last?.message == "Abschnitt „Bereitstellungsraum“ gelöscht, 2 Einheiten ohne Abschnitt")
        #expect(throws: CommandError.notFound(.section)) {
            try store.perform(RenameSection(sectionID: initial.id, name: "X"))
        }

        // Neu geladen identisch.
        let inMemory = store.state
        try store.reload()
        #expect(store.state == inMemory)
    }

    @Test func templateSavedOnlyOnce() {
        var master = MasterDataSet()
        let added = master.addSection(named: "Patientenablage")
        let again = master.addSection(named: "  patientenablage ")
        #expect(added)
        #expect(!again, "Groß/klein und Leerraum egal")
        #expect(master.sections.map(\.name) == ["Patientenablage"])
        #expect(master.revision == 1)
    }
}
