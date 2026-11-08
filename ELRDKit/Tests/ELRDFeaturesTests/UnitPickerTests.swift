import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Transportmittel-Liste am Patienten")
@MainActor
struct UnitPickerTests {
    @Test func searchFindsMissionAndMasterUnitsAndOffersNewOne() throws {
        let store = try PreviewData.makeStore() // Platzhalter: 2 RTW, 1 NEF
        try store.perform(AddTemporaryUnit(callsign: "RK SWFT 71/1", type: .rtw))
        let master = [
            MasterUnit(callsign: "RK SWFT 71/1", type: .rtw),
            MasterUnit(callsign: "RK SWFT 72/1", type: .ktw),
            MasterUnit(callsign: "RK SWFT 76/1", type: .nef),
        ]
        let patient = try #require(store.state.activePatients.first)
        let choices = UnitChoice.ordered(units: store.state.units, patients: store.state.patients, for: patient.id)

        var search = UnitPickerSearch()
        #expect(search.filter(choices).count == choices.count)
        #expect(search.masterUnits(master, excluding: store.state.units).map(\.callsign) == ["RK SWFT 72/1", "RK SWFT 76/1"], "ohne Suche alle Stammdaten, die noch nicht im Einsatz sind")
        search.text = "SWFT"
        #expect(search.masterUnits(master, excluding: store.state.units).map(\.callsign) == ["RK SWFT 72/1", "RK SWFT 76/1"],
                "nur, was noch nicht im Einsatz ist; Transportmittel zuerst")
        search.text = ""
        #expect(search.newCallsign(units: store.state.units, master: master) == nil)

        search.text = "71"
        #expect(search.filter(choices).map(\.unit.displayName).contains { $0.contains("71/1") })
        #expect(search.masterUnits(master, excluding: store.state.units).isEmpty, "schon im Einsatz")

        search.text = "76"
        #expect(search.masterUnits(master, excluding: store.state.units).map(\.callsign) == ["RK SWFT 76/1"], "mit Suche auch NEF")

        search.text = " Florian SW 1 "
        #expect(search.newCallsign(units: store.state.units, master: master) == "Florian SW 1")
        search.text = "rk swft 72/1"
        #expect(search.newCallsign(units: store.state.units, master: master) == nil, "bekannt aus den Stammdaten")
    }

    @Test func newUnitIsAddedAndAssigned() throws {
        let store = try PreviewData.makeStore()
        let patient = try #require(store.state.activePatients.first)
        let unit = try store.perform(AddTemporaryUnit(callsign: "Florian SW 1", type: .rtw))
        try store.perform(AssignUnit(patientID: patient.id, unitID: unit.id))
        let groups = UnitAssignmentGroups(UnitChoice.ordered(units: store.state.units, patients: store.state.patients, for: patient.id))
        #expect(groups.assigned.map(\.id) == [unit.id])
    }

    @Test func registrationStatesHaveDistinctColors() {
        let states: [HospitalRegistrationState] = [.nichtAngefragt, .angefragt, .angemeldet]
        #expect(Set(states.map(\.color)).count == 3)
    }
}
