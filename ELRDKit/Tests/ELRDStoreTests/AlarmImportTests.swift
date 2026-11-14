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

    // MARK: Schritt 143: neuer Stand nach der Übernahme

    func updated(_ base: AlamosAlarm, revision: Int? = nil) -> AlamosAlarm {
        var data = base.data
        data.keyword = "RD 5"
        data.message.append("Zweiter Bus beteiligt")
        data.vehicles.append(AlamosVehicle(unitType: "RTW", radioName: "JOH SWFT 71/1"))
        data.vehicles.append(AlamosVehicle(radioName: "RK SWFT 76/1"))
        data.patients.append(AlamosPatient(name: "Erika Muster", remark: "Schock", patientNumber: "3"))
        return AlamosAlarm(id: base.id, externalId: base.externalId, revision: revision ?? base.revision + 1, receivedAt: base.receivedAt, data: data)
    }

    func imported(_ first: AlamosAlarm, fixture: StoreFixture) throws -> MissionStore {
        var request = NewMissionRequest(reason: "VU Reisebus")
        request.alarmImport = AlarmImport(alarm: first, masterUnits: [rtw, nef])
        return try create(request, fixture: fixture)
    }

    @Test func updateOffersOnlyNewAndApplies() throws {
        let fixture = try StoreFixture()
        let first = alarm()
        let store = try imported(first, fixture: fixture)
        #expect(store.state.mission.externalAlarm?.applied?.patientKeys == ["1", "2"])
        #expect(AlarmUpdate(alarm: first, state: store.state) == nil, "gleicher Stand")

        let second = updated(first)
        let update = try #require(AlarmUpdate(alarm: second, state: store.state, masterUnits: [rtw, nef]))
        #expect(update.changes.keyword == "RD 4 → RD 5 – VU Reisebus")
        #expect(update.changes.callsigns == ["JOH SWFT 71/1"], "RK SWFT 76/1 war schon alarmiert")
        #expect(update.vehicles.map(\.callsign) == ["JOH SWFT 71/1"])
        #expect(update.vehicles.first?.type == .rtw)
        #expect(update.changes.patients.count == 1)
        #expect(update.changes.messageLines == ["Zweiter Bus beteiligt"])
        #expect(!update.changes.summary.joined().contains("Erika"), "keine Namen in der Kurzfassung")

        let unitsBefore = store.state.units.filter { !$0.isDeleted }.count
        try store.perform(ApplyAlarmUpdate(alarm: second, masterUnits: [rtw, nef]))
        let state = store.state
        #expect(state.mission.externalAlarm?.revision == 3)
        #expect(state.units.filter { !$0.isDeleted }.count == unitsBefore + 1)
        #expect(state.units.contains { $0.callsign == "JOH SWFT 71/1" && $0.type == .rtw && !$0.isDeleted })
        #expect(state.patients.filter { !$0.isDeleted }.count == 3)
        #expect(state.patients.contains { $0.dispatchPatientNumber == "3" && $0.lastName == "Muster" && $0.triage == .ungesichtet })
        #expect(state.journal.contains { $0.text.contains("Änderung aus Alamos FE2 übernommen") && $0.text.contains("Nachalarmiert: JOH SWFT 71/1") && $0.text.contains("RD 4 → RD 5") })
        #expect(AlarmUpdate(alarm: second, state: state) == nil, "übernommen")
        #expect(throws: CommandError.self) { try store.perform(ApplyAlarmUpdate(alarm: second)) }
    }

    @Test func dismissHidesUntilNextRevision() throws {
        let fixture = try StoreFixture()
        let first = alarm()
        let store = try imported(first, fixture: fixture)
        let unitsBefore = store.state.units.filter { !$0.isDeleted }.count
        let second = updated(first)
        try store.perform(DismissAlarmUpdate(revision: second.revision))
        #expect(AlarmUpdate(alarm: second, state: store.state) == nil)
        #expect(store.state.units.filter { !$0.isDeleted }.count == unitsBefore, "nichts angelegt")

        // Nächster Stand: wieder Hinweis, mit allem seit der letzten Übernahme.
        let third = updated(first, revision: 4)
        let again = try #require(AlarmUpdate(alarm: third, state: store.state))
        #expect(again.changes.callsigns == ["JOH SWFT 71/1"])
    }

    @Test func partialApplyLeavesRestOpen() throws {
        let fixture = try StoreFixture()
        let first = alarm()
        let store = try imported(first, fixture: fixture)
        let second = updated(first)
        let full = try #require(AlarmUpdate(alarm: second, state: store.state))
        #expect(full.fullSelection.count == 4, "Stichwort, Alarmtext, 1 Fahrzeug, 1 Patient")

        try store.perform(ApplyAlarmUpdate(alarm: second, selection: AlarmUpdateSelection(vehicleKeys: [MasterDataMatching.key("JOH SWFT 71/1")])))
        #expect(store.state.units.contains { $0.callsign == "JOH SWFT 71/1" && !$0.isDeleted })
        #expect(store.state.patients.filter { !$0.isDeleted }.count == 2, "Patient nicht ausgewählt")
        #expect(store.state.journal.contains { $0.text.contains("Nachalarmiert: JOH SWFT 71/1") && !$0.text.contains("Stichwort") })

        let rest = try #require(AlarmUpdate(alarm: second, state: store.state), "Rest bleibt offen")
        #expect(rest.changes.callsigns.isEmpty)
        #expect(rest.changes.patientKeys == ["3"])
        #expect(rest.changes.keyword != nil)
        #expect(rest.changes.messageLines == ["Zweiter Bus beteiligt"])

        try store.perform(ApplyAlarmUpdate(alarm: second, selection: AlarmUpdateSelection(keyword: true, message: true, patientKeys: ["3"])))
        #expect(AlarmUpdate(alarm: second, state: store.state) == nil, "alles erledigt")
        #expect(store.state.patients.filter { !$0.isDeleted }.count == 3)
        #expect(throws: CommandError.self) { try store.perform(ApplyAlarmUpdate(alarm: second, selection: AlarmUpdateSelection())) }
    }

    @Test func vehicleAddedByHandIsNotOfferedAgain() throws {
        let fixture = try StoreFixture()
        let first = alarm()
        let store = try imported(first, fixture: fixture)
        try store.perform(AddTemporaryUnit(callsign: "JOH SWFT 71/1", type: .rtw))
        let update = try #require(AlarmUpdate(alarm: updated(first), state: store.state))
        #expect(update.changes.callsigns.isEmpty)
        #expect(update.vehicles.isEmpty)
    }

    @Test func otherMissionOrOlderReferenceWithoutSnapshot() throws {
        let fixture = try StoreFixture()
        let first = alarm()
        let store = try imported(first, fixture: fixture)
        let foreign = AlamosAlarm(externalId: "anderer", revision: 9, receivedAt: first.receivedAt, data: updated(first).data)
        #expect(AlarmUpdate(alarm: foreign, state: store.state) == nil)

        // Vor Schritt 143 übernommen: Vergleich mit Fahrzeugen und Patienten im Einsatz.
        var mission = store.state.mission
        mission.externalAlarm?.applied = nil
        let update = try #require(AlarmUpdate(alarm: updated(first), mission: mission, units: store.state.units, patients: store.state.patients))
        #expect(update.changes.keyword == nil, "Stichwort unbekannt → nicht gemeldet")
        #expect(update.changes.callsigns == ["JOH SWFT 71/1"])
        #expect(update.changes.patients.count == 1)
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
