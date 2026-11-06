import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Platzhalter und Alarmstichworte")
@MainActor
struct PlaceholderCommandTests {
    let rtw = MasterUnit(callsign: "RK SWFT 71/1", type: .rtw, crewCount: 2)
    let hvo = MasterUnit(callsign: "HvO Musterdorf", type: .sonstiges, typeLabel: "HVO")

    @Test func placeholdersNumberOnAcrossTypes() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission() // Bereitstellungsraum (Initial), Patientenablage
        let initial = try #require(MissionSection.initialSection(in: store.state.sections))
        let stichwort = try store.perform(AddAlarmstichwort(.rd2))
        #expect(stichwort.map(\.displayName) == ["RTW (Platzhalter 1)", "NEF (Platzhalter 2)"])
        #expect(stichwort.allSatisfy { $0.sectionID == initial.id })
        #expect(store.state.visibleLog.last?.message == "Alarmstichwort RD 2 hinzugefügt: 1 RTW, 1 NEF → „Bereitstellungsraum“")

        let other = store.state.activeSections[1]
        let ktw = try store.perform(AddPlaceholder(type: .ktw, sectionID: other.id))
        #expect(ktw.displayName == "KTW (Platzhalter 3)")
        #expect(ktw.sectionID == other.id)
        #expect(store.state.visibleLog.last?.message == "KTW (Platzhalter 3) angelegt → „Patientenablage“")
    }

    @Test func replaceWithMasterUnitKeepsIdentityAndPatients() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let placeholder = try #require(try store.perform(AddAlarmstichwort(.rd1)).first)
        let patient = try store.perform(AddPatient(triage: .sk2))
        try store.perform(AssignUnit(patientID: patient.id, unitID: placeholder.id))

        let replaced = try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: .master(rtw)))
        #expect(replaced.id == placeholder.id)
        #expect(!replaced.isPlaceholder)
        #expect(replaced.displayName == "RK SWFT 71/1")
        #expect(replaced.masterUnitID == rtw.id)
        #expect(replaced.crewCount == 2)
        #expect(replaced.sectionID == placeholder.sectionID)
        #expect(store.state.patients.first { $0.id == patient.id }?.unitIDs == [placeholder.id], "Zuordnung bleibt")
        #expect(store.state.visibleLog.last?.message == "RTW (Platzhalter 1) ist RK SWFT 71/1")

        #expect(throws: CommandError.invalid("RK SWFT 71/1 ist kein Platzhalter mehr.")) {
            try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: .master(hvo)))
        }
    }

    @Test func replaceRejectsUnitsAlreadyInMission() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        _ = try store.perform(AddMasterUnits([rtw]))
        let placeholder = try store.perform(AddPlaceholder(type: .rtw))
        #expect(throws: CommandError.invalid("„RK SWFT 71/1“ ist schon im Einsatz.")) {
            try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: .master(rtw)))
        }
        #expect(throws: CommandError.invalid("„rk swft 71/1“ ist schon im Einsatz.")) {
            try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: .temporary(callsign: " rk swft 71/1 ", type: .rtw)))
        }
        #expect(throws: CommandError.invalid("Bitte einen Funkrufnamen eingeben.")) {
            try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: .temporary(callsign: "  ", type: .rtw)))
        }
        let typed = try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: .temporary(callsign: "RK Musterstadt 71/2", type: .rtw)))
        #expect(typed.isTemporary)
        #expect(typed.displayName == "RK Musterstadt 71/2")
    }

    @Test func replaceKeepsOriginalTypeLabel() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let placeholder = try store.perform(AddPlaceholder(type: .rtw))
        let replaced = try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: .master(hvo)))
        #expect(replaced.type == .sonstiges)
        #expect(replaced.typeDisplayName == "HVO")
    }
}
