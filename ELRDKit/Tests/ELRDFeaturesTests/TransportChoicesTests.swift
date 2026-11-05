import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Einheiten- und Klinikauswahl")
@MainActor
struct TransportChoicesTests {
    @Test func unitsAssignedFirstThenFreeThenBusy() throws {
        let store = try PreviewData.makeStore() // RD 3: 2 RTW, 1 NEF
        let patients = store.state.activePatients
        let rtws = store.state.activeUnits.filter { $0.type == .rtw }
        let nef = try #require(store.state.activeUnits.first { $0.type == .nef })
        try store.perform(AssignUnit(patientID: patients[1].id, unitID: rtws[0].id))
        try store.perform(AssignUnit(patientID: patients[0].id, unitID: nef.id))

        let choices = UnitChoice.ordered(units: store.state.units, patients: store.state.patients, for: patients[0].id)
        #expect(choices.map(\.id) == [nef.id, rtws[1].id, rtws[0].id], "eigene, frei (RTW vor NEF), belegt")
        #expect(choices[0].isAssigned)
        #expect(choices[1].isFree)
        #expect(choices[2].otherPatients == [patients[1].number.description])
        #expect(choices[2].label == "\(rtws[0].displayName) · \(patients[1].number)")
    }

    @Test func hospitalsUsedInMissionFirstThenNearest() throws {
        let here = try #require(GeoCoordinate(latitude: 50.10, longitude: 10.18))
        let near = MasterHospital(name: "Nah", city: "A", coordinate: GeoCoordinate(latitude: 50.11, longitude: 10.18))
        let far = MasterHospital(name: "Fern", city: "B", coordinate: GeoCoordinate(latitude: 50.50, longitude: 10.18))
        let used = MasterHospital(name: "Gewählt", city: "C", coordinate: GeoCoordinate(latitude: 50.80, longitude: 10.18))
        let unknown = MasterHospital(name: "Ohne Ort", city: "D")
        var patient = Patient(missionID: MissionID(), metadata: .new(by: nil, at: Date()), number: SerialNumber(prefix: "A", value: 1)!)
        patient.setDestination(used.snapshot)

        let ordered = HospitalChoice.ordered(hospitals: [unknown, far, used, near], patients: [patient], near: here)
        #expect(ordered.map(\.hospital.name) == ["Gewählt", "Nah", "Fern", "Ohne Ort"])
        #expect(ordered[1].distanceText == "1.1 km")
        #expect(ordered[0].usedInMission == 1)

        let noLocation = HospitalChoice.ordered(hospitals: [far, near, unknown], patients: [], near: nil)
        #expect(noLocation.map(\.hospital.name) == ["Fern", "Nah", "Ohne Ort"], "ohne Einsatzort alphabetisch")

        #expect(HospitalChoice.filter(ordered, search: "fe").map(\.hospital.name) == ["Fern"])
    }

    @Test func distanceIsPlausible() throws {
        let schweinfurt = try #require(GeoCoordinate(latitude: 50.0492, longitude: 10.2194))
        let wuerzburg = try #require(GeoCoordinate(latitude: 49.7913, longitude: 9.9534))
        let km = schweinfurt.distance(to: wuerzburg) / 1000
        #expect(km > 30 && km < 40, "Luftlinie Schweinfurt–Würzburg ca. 35 km")
        #expect(schweinfurt.distance(to: schweinfurt) == 0)
    }
}
