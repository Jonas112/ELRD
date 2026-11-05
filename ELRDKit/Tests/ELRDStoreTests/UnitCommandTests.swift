import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Einheiten hinzufügen und entfernen")
@MainActor
struct UnitCommandTests {
    let rtw = MasterUnit(callsign: "RK SWFT 71/1", type: .rtw)
    let hvo = MasterUnit(callsign: "HvO Musterdorf", type: .sonstiges, typeLabel: "HVO")

    @Test func masterUnitsGoToInitialSectionOnlyOnce() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission() // Bereitstellungsraum (Initial), Patientenablage
        let initial = try #require(MissionSection.initialSection(in: store.state.sections))
        let added = try store.perform(AddMasterUnits([rtw, hvo, rtw]))
        #expect(added.map(\.displayName) == ["RK SWFT 71/1", "HvO Musterdorf"], "doppelte übersprungen")
        #expect(added.allSatisfy { $0.sectionID == initial.id })
        #expect(added[1].typeDisplayName == "HVO", "Originalbezeichnung bleibt (E38)")
        #expect(added[0].masterUnitID == rtw.id)
        #expect(store.state.visibleLog.last?.message == "HvO Musterdorf hinzugefügt → „Bereitstellungsraum“")

        let again = try store.perform(AddMasterUnits([rtw]))
        #expect(again.isEmpty, "schon im Einsatz")

        let other = store.state.activeSections[1]
        let moved = try store.perform(AddMasterUnits([MasterUnit(callsign: "RK SWFT 76/1", type: .nef)], sectionID: other.id))
        #expect(moved.first?.sectionID == other.id)
    }

    @Test func temporaryUnitRejectsDuplicateCallsign() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        _ = try store.perform(AddMasterUnits([rtw]))
        let temp = try store.perform(AddTemporaryUnit(callsign: "  Florian Musterstadt 1 ", type: .elw))
        #expect(temp.displayName == "Florian Musterstadt 1")
        #expect(temp.isTemporary)
        #expect(store.state.visibleLog.last?.message == "Florian Musterstadt 1 (temporär) hinzugefügt → „Bereitstellungsraum“")
        #expect(throws: CommandError.invalid("„rk swft 71/1“ ist schon im Einsatz.")) {
            try store.perform(AddTemporaryUnit(callsign: "rk swft 71/1", type: .rtw))
        }
        #expect(throws: CommandError.invalid("Bitte einen Funkrufnamen eingeben.")) {
            try store.perform(AddTemporaryUnit(callsign: "   ", type: .rtw))
        }
    }

    @Test func removeOnlyWithoutOpenPatients() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let unit = try #require(try store.perform(AddMasterUnits([rtw])).first)
        let patient = try store.perform(AddPatient(triage: .sk2))
        try store.perform(AssignUnit(patientID: patient.id, unitID: unit.id))
        #expect(throws: CommandError.invalid("RK SWFT 71/1 ist noch Patient A-1 zugeordnet. Zuerst die Zuordnung lösen.")) {
            try store.perform(RemoveUnit(unitID: unit.id))
        }
        try store.perform(ReleasePatient(patientID: patient.id))
        try store.perform(RemoveUnit(unitID: unit.id))
        #expect(store.state.activeUnits.isEmpty)
        #expect(store.state.visibleLog.last?.message == "RK SWFT 71/1 aus dem Einsatz entfernt")
        let again = try store.perform(AddMasterUnits([rtw]))
        #expect(again.count == 1, "nach dem Entfernen wieder wählbar")

        let inMemory = store.state
        try store.reload()
        #expect(store.state == inMemory)
    }

    @Test func masterDataKeepsTemporaryUnitOnce() {
        var master = MasterDataSet()
        let first = master.addUnit(callsign: "Florian Musterstadt 1", type: .elw)
        let second = master.addUnit(callsign: "florian  musterstadt 1", type: .elw)
        #expect(first?.origin == .fromMission)
        #expect(second == nil)
        #expect(master.units.count == 1)
    }
}
