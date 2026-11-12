import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDStore

/// Schritt 140: Einsatz aus Alamos FE2 übernehmen.
@MainActor
struct AlarmImportTests {
    let rtw = MasterUnit(callsign: "RK SWFT 71/1", type: .rtw)
    let nef = MasterUnit(callsign: "RK SWFT 76/1", type: .nef)

    func alarm(revision: Int = 2) -> AlamosAlarm {
        AlamosAlarm(
            externalId: "2611-4711",
            revision: revision,
            receivedAt: Date(timeIntervalSince1970: 1_792_000_000),
            data: AlamosAlarmData(
                externalId: "2611-4711",
                keyword: "RD 4",
                keywordDescription: "VU Reisebus",
                message: ["Bus auf Seite"],
                location: AlamosLocation(coordinate: [10.1003, 49.9811], street: "A 70", postalCode: "97440", city: "Werneck"),
                patients: [
                    AlamosPatient(name: "Max Mustermann", remark: "eingeklemmt", destination: "Leopoldina", patientNumber: "1"),
                    AlamosPatient(remark: "gehfähig", patientNumber: "2"),
                ],
                vehicles: [
                    AlamosVehicle(unitType: "RTW", radioName: "rk swft 71/1"),
                    AlamosVehicle(unitType: "NEF", radioName: "RK SWFT 76/1"),
                    AlamosVehicle(radioName: "RK SWFT 76/1"),
                    AlamosVehicle(unitType: "KTW", radioName: "MHD SW 72/9"),
                ]
            )
        )
    }

    func create(_ request: NewMissionRequest, fixture: StoreFixture) throws -> MissionStore {
        let clock = fixture.clock
        return try MissionStore.create(
            request,
            repository: fixture.repository,
            session: fixture.session(fixture.deviceA),
            clock: try DeviceClock(deviceID: fixture.deviceA.deviceID, repository: fixture.repository),
            now: { clock.now }
        )
    }

    @Test func importsLocationJournalVehiclesAndPatients() throws {
        let fixture = try StoreFixture()
        var request = NewMissionRequest(reason: "VU Reisebus", location: "A 70, 97440 Werneck", dispatchNumber: "2611-4711", sectionNames: ["Patientenablage"], initialSectionName: "Patientenablage")
        request.alarmImport = AlarmImport(alarm: alarm(), masterUnits: [rtw, nef])
        let store = try create(request, fixture: fixture)
        let state = store.state

        #expect(state.mission.externalAlarm?.externalID == "2611-4711")
        #expect(state.mission.externalAlarm?.revision == 2)
        #expect(state.mission.coordinate?.latitude == 49.9811)
        #expect(state.mission.coordinate?.longitude == 10.1003)
        #expect(state.journal.contains { $0.origin == .automatic && $0.text.contains("Einsatz aus Alamos FE2 übernommen") && $0.text.contains("Bus auf Seite") })

        let units = state.units.filter { !$0.isDeleted }
        #expect(units.count == 3, "RTW und NEF aus den Stammdaten, KTW temporär, Doppelte übersprungen")
        #expect(units.filter { $0.masterUnitID != nil }.count == 2)
        #expect(units.contains { $0.callsign == "MHD SW 72/9" && $0.type == .ktw && $0.masterUnitID == nil })
        #expect(units.allSatisfy { $0.sectionID != nil }, "im Initialabschnitt")

        let patients = state.patients.filter { !$0.isDeleted }
        #expect(patients.count == 2)
        let max = try #require(patients.first { $0.dispatchPatientNumber == "1" })
        #expect(max.firstName == "Max")
        #expect(max.lastName == "Mustermann")
        #expect(max.triage == .ungesichtet)
        #expect(max.notes.contains("Leitstelle: eingeklemmt"))
        #expect(max.notes.contains("Ziel lt. Leitstelle: Leopoldina"))
        #expect(patients.contains { $0.dispatchPatientNumber == "2" && $0.firstName.isEmpty })

        // Einsatzliste kennt den Bezug (für „übernommen“).
        let summaries = try MissionOverview.load(from: fixture.repository)
        #expect(summaries.first?.externalAlarmID == "2611-4711")
    }

    @Test func importWithoutVehiclesAndPatients() throws {
        let fixture = try StoreFixture()
        var request = NewMissionRequest(reason: "VU Reisebus", alarmstichwort: .rd2)
        request.alarmImport = AlarmImport(alarm: alarm(), includesVehicles: false, includesPatients: false, masterUnits: [rtw])
        let state = try create(request, fixture: fixture).state
        #expect(state.patients.isEmpty)
        #expect(state.units.allSatisfy { $0.isPlaceholder }, "nur Platzhalter des Stichworts")
        #expect(state.mission.externalAlarm != nil)
    }

    @Test func vehicleMatchesForPreview() {
        let matches = AlarmImport(alarm: alarm(), masterUnits: [rtw, nef]).vehicleMatches
        #expect(matches.map(\.callsign) == ["RK SWFT 71/1", "RK SWFT 76/1", "MHD SW 72/9"])
        #expect(matches.map { $0.master != nil } == [true, true, false])
    }

    @Test func splitsNames() {
        func split(_ name: String?) -> String {
            let parts = AlarmImport.splitName(name)
            return "\(parts.first ?? "–")|\(parts.last ?? "–")"
        }
        #expect(split("Max Mustermann") == "Max|Mustermann")
        #expect(split("Mustermann, Max") == "Max|Mustermann")
        #expect(split("Anna Maria Muster") == "Anna Maria|Muster")
        #expect(split("Unbekannt") == "–|Unbekannt")
        #expect(split("  ") == "–|–")
        #expect(split(nil) == "–|–")
    }
}
