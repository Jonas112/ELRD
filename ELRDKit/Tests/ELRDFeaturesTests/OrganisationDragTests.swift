import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Ziehen und Ablegen in der Organisation")
@MainActor
struct OrganisationDragTests {
    @Test func payloadRoundTripsAndIgnoresForeignText() {
        let unit = UnitID()
        let patient = PatientID()
        #expect(DragPayload(text: DragPayload.unit(unit).text) == .unit(unit))
        #expect(DragPayload(text: DragPayload.patient(patient).text) == .patient(patient))
        #expect(DragPayload(text: "RK SWFT 71/1") == nil)
        #expect(DragPayload(text: "elrd-unit:kaputt") == nil)
    }

    @Test func unitDropsMoveOrAssign() throws {
        let store = try PreviewData.makeStore() // RD 3 im Bereitstellungsraum
        let sections = store.state.activeSections
        let units = store.state.activeUnits
        let rtw = try #require(units.first { $0.type == .rtw })
        let nef = try #require(units.first { $0.type == .nef })
        let patient = store.state.activePatients[0]
        let state = store.state

        #expect(DropAction.actions(for: .unit(rtw.id), onto: .section(sections[1].id), in: state) == [.moveUnit(rtw.id, to: sections[1].id)])
        #expect(DropAction.actions(for: .unit(rtw.id), onto: .section(sections[0].id), in: state).isEmpty, "schon dort")
        #expect(DropAction.actions(for: .unit(rtw.id), onto: .unit(nef.id), in: state).isEmpty, "gleicher Abschnitt")
        #expect(DropAction.actions(for: .unit(rtw.id), onto: .unit(rtw.id), in: state).isEmpty)
        #expect(DropAction.actions(for: .unit(rtw.id), onto: .loosePatient(patient.id, section: sections[1].id), in: state)
            == [.assign(patient: patient.id, unit: rtw.id), .moveUnit(rtw.id, to: sections[1].id)])
        #expect(DropAction.actions(for: .unit(UnitID()), onto: .section(nil), in: state).isEmpty, "unbekannte Einheit")
    }

    @Test func patientDropsAssignOrPlace() throws {
        let store = try PreviewData.makeStore()
        let section = store.state.activeSections[1]
        let rtw = try #require(store.state.activeUnits.first { $0.type == .rtw })
        let patient = store.state.activePatients[0]
        let state = store.state

        #expect(DropAction.actions(for: .patient(patient.id), onto: .unit(rtw.id), in: state) == [.assign(patient: patient.id, unit: rtw.id)])
        #expect(DropAction.actions(for: .patient(patient.id), onto: .section(section.id), in: state) == [.movePatient(patient.id, to: section.id)])
        #expect(DropAction.actions(for: .patient(patient.id), onto: .loosePatient(PatientID(), section: nil), in: state).isEmpty)
    }

    @Test func patientWithUnitCannotBePlacedAlone() throws {
        let store = try PreviewData.makeStore()
        let section = store.state.activeSections[1]
        let rtw = try #require(store.state.activeUnits.first { $0.type == .rtw })
        let patient = store.state.activePatients[0]
        try store.perform(MovePatient(patientID: patient.id, to: section.id))
        #expect(store.state.visibleLog.last?.message == "Patient A-1 → „Patientenablage“")
        #expect(SectionColumn.columns(for: store.state)[1].loosePatients.map(\.id) == [patient.id])

        try store.perform(AssignUnit(patientID: patient.id, unitID: rtw.id))
        #expect(throws: CommandError.invalid("Patient A-1 ist RTW (Platzhalter 1) zugeordnet. Die Einheit in den Abschnitt verschieben.")) {
            try store.perform(MovePatient(patientID: patient.id, to: nil))
        }
    }
}
