import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDStore

@Suite("Verteilungsvorschlag und Lagebilder (Schritte 108–109)")
@MainActor
struct DistributionSnapshotTests {
    let fixture: StoreFixture

    init() throws {
        fixture = try StoreFixture()
    }

    // Einsatzort und zwei Kliniken: „Nah“ rund 1 km, „Fern“ rund 10 km entfernt.
    private let origin = GeoCoordinate(latitude: 50.0, longitude: 10.0)!
    private var near: MasterHospital {
        MasterHospital(name: "Klinik Nah", coordinate: GeoCoordinate(latitude: 50.009, longitude: 10.0))
    }
    private var far: MasterHospital {
        MasterHospital(name: "Klinik Fern", coordinate: GeoCoordinate(latitude: 50.09, longitude: 10.0))
    }

    private func setUp(_ store: MissionStore, near: MasterHospital, far: MasterHospital) throws {
        let origin = self.origin
        try store.perform(EditMission { $0.coordinate = origin })
        try store.perform(SetHospitalQuota(HospitalQuota(masterHospitalID: near.id, hospitalName: near.name, sk1: 1, sk2: 1)))
        try store.perform(SetHospitalQuota(HospitalQuota(masterHospitalID: far.id, hospitalName: far.name, sk1: 2, sk2: 2, sk3: 3)))
    }

    // MARK: 108 Verteilungsvorschlag

    @Test func proposesNearestFreeHospitalBySeverity() throws {
        let store = try fixture.newMission()
        let near = self.near, far = self.far
        try setUp(store, near: near, far: far)
        let sk2 = try store.perform(AddPatient(triage: .sk2))
        fixture.clock.advance(60)
        let firstSK1 = try store.perform(AddPatient(triage: .sk1))
        fixture.clock.advance(60)
        let secondSK1 = try store.perform(AddPatient(triage: .sk1))
        let sk3 = try store.perform(AddPatient(triage: .sk3))
        _ = try store.perform(AddPatient(triage: .ungesichtet))

        let plan = HospitalDistribution.propose(store.state, hospitals: [near, far])
        #expect(plan.hasQuotas)
        #expect(plan.proposals.map(\.patientID) == [firstSK1.id, secondSK1.id, sk2.id, sk3.id], "SK1 zuerst, ungesichtet nicht")
        let byPatient = Dictionary(uniqueKeysWithValues: plan.proposals.map { ($0.patientID, $0.hospital.name) })
        #expect(byPatient[firstSK1.id] == "Klinik Nah", "nächste Klinik für den ältesten SK1")
        #expect(byPatient[secondSK1.id] == "Klinik Fern", "Nah hat nur einen SK1-Platz")
        #expect(byPatient[sk2.id] == "Klinik Nah")
        #expect(byPatient[sk3.id] == "Klinik Fern", "Nah hat kein SK3-Kontingent")
        let first = try #require(plan.proposals.first)
        #expect(first.hospital.masterHospitalID == near.id, "Stammdaten samt Adresse übernommen")
        #expect((first.distanceMeters ?? 0) > 900 && (first.distanceMeters ?? 0) < 1100)
        #expect(first.reason.contains("1,0 km"))
        #expect(plan.undistributed.isEmpty)
    }

    @Test func respectsAssignedPatientsAndReportsShortage() throws {
        let store = try fixture.newMission()
        let near = self.near, far = self.far
        try setUp(store, near: near, far: far)
        // Belegt: ein SK1 schon in „Nah“, zwei in „Fern“.
        for hospital in [near, far, far] {
            let patient = try store.perform(AddPatient(triage: .sk1))
            try store.perform(SetDestination(patientID: patient.id, hospital: hospital.snapshot))
        }
        let waiting = try store.perform(AddPatient(triage: .sk1))
        try store.perform(EditPatient(patientID: waiting.id) { $0.traumaRoom = .a })

        let plan = HospitalDistribution.propose(store.state, hospitals: [near, far])
        #expect(plan.proposals.isEmpty)
        #expect(plan.undistributed.map(\.patientID) == [waiting.id])
        #expect(plan.undistributed.first?.reason == "Kein freier Platz für SK 1")
    }

    @Test func withoutQuotasNothingIsProposed() throws {
        let store = try fixture.newMission()
        _ = try store.perform(AddPatient(triage: .sk2))
        let plan = HospitalDistribution.propose(store.state, hospitals: [near])
        #expect(!plan.hasQuotas)
        #expect(plan.proposals.isEmpty)
        #expect(plan.undistributed.count == 1)
    }

    @Test func traumaRoomGoesFirstAndIsNamed() throws {
        let store = try fixture.newMission()
        let near = self.near, far = self.far
        try setUp(store, near: near, far: far)
        let early = try store.perform(AddPatient(triage: .sk2))
        fixture.clock.advance(60)
        let room = try store.perform(AddPatient(triage: .sk2))
        try store.perform(EditPatient(patientID: room.id) { $0.traumaRoom = .b })

        let plan = HospitalDistribution.propose(store.state, hospitals: [near, far])
        #expect(plan.proposals.map(\.patientID) == [room.id, early.id], "Schockraum-Bedarf bekommt den nächsten Platz")
        #expect(plan.proposals.first?.hospital.name == "Klinik Nah")
        #expect(plan.proposals.first?.reason.contains("Schockraum B anmelden") == true)
    }

    @Test func withoutCoordinatesStillProposes() throws {
        let store = try fixture.newMission()
        try store.perform(SetHospitalQuota(HospitalQuota(hospitalName: "Kreisklinik", sk3: 2)))
        let patient = try store.perform(AddPatient(triage: .sk3))
        let plan = HospitalDistribution.propose(store.state, hospitals: [])
        #expect(plan.proposals.first?.patientID == patient.id)
        #expect(plan.proposals.first?.hospital.name == "Kreisklinik")
        #expect(plan.proposals.first?.distanceMeters == nil)
        #expect(plan.proposals.first?.reason == "Freier Platz für SK 3")
    }

    @Test func applyDistributionSetsDestinations() throws {
        let store = try fixture.newMission()
        let near = self.near, far = self.far
        try setUp(store, near: near, far: far)
        let first = try store.perform(AddPatient(triage: .sk1))
        let second = try store.perform(AddPatient(triage: .sk2))
        try store.perform(ApplyDistribution([
            .init(patientID: first.id, hospital: near.snapshot),
            .init(patientID: second.id, hospital: far.snapshot),
        ]))
        let patients = Dictionary(uniqueKeysWithValues: store.state.patients.map { ($0.id, $0) })
        #expect(patients[first.id]?.destination?.name == "Klinik Nah")
        #expect(patients[second.id]?.destination?.name == "Klinik Fern")
        #expect(store.state.logEntries.contains { $0.message == "Verteilungsvorschlag für 2 Patienten übernommen" })
        #expect(HospitalDistribution.propose(store.state, hospitals: [near, far]).isEmpty, "danach nichts mehr offen")
    }

    @Test func distanceText() {
        #expect(HospitalDistribution.distanceText(847) == "850 m")
        #expect(HospitalDistribution.distanceText(4_230) == "4,2 km")
        #expect(HospitalDistribution.distanceText(23_600) == "24 km")
    }

    // MARK: 109 Lagebilder

    @Test func snapshotIsDueByInterval() throws {
        let store = try fixture.newMission()
        #expect(!SituationSnapshot.isDue(store.state, intervalMinutes: 0, now: fixture.clock.now), "aus")
        #expect(!SituationSnapshot.isDue(store.state, intervalMinutes: 15, now: fixture.clock.now))
        fixture.clock.advance(15 * 60)
        #expect(SituationSnapshot.isDue(store.state, intervalMinutes: 15, now: fixture.clock.now), "15 min nach Einsatzbeginn")

        let entry = try #require(try store.perform(AddSituationSnapshot(text: "Lagebild", minimumGap: 7.5 * 60)))
        #expect(entry.isSituationSnapshot == true)
        #expect(entry.origin == .automatic)
        #expect(SituationSnapshot.latest(in: store.state.journal) == fixture.clock.now)
        #expect(!SituationSnapshot.isDue(store.state, intervalMinutes: 15, now: fixture.clock.now))

        // Zweites Gerät kurz danach: Sperre greift, kein doppelter Eintrag.
        fixture.clock.advance(60)
        #expect(try store.perform(AddSituationSnapshot(text: "Lagebild", minimumGap: 7.5 * 60)) == nil)
        #expect(store.state.journal.filter { $0.isSituationSnapshot == true }.count == 1)

        fixture.clock.advance(14 * 60)
        #expect(SituationSnapshot.isDue(store.state, intervalMinutes: 15, now: fixture.clock.now))
    }

    @Test func snapshotIsNotALagemeldung() throws {
        let store = try fixture.newMission()
        let entry = try #require(try store.perform(AddSituationSnapshot(text: "Lagebild")))
        #expect(entry.category == nil, "Lagebild setzt die Erinnerung an die Lagemeldung nicht zurück")
    }

    @Test func snapshotTextCountsWithoutNames() throws {
        let store = try fixture.newMission()
        let sk1 = try store.perform(AddPatient(triage: .sk1))
        try store.perform(EditPatient(patientID: sk1.id) { $0.lastName = "Mustermann" })
        _ = try store.perform(AddPatient(triage: .sk2))
        _ = try store.perform(AddPatient(triage: .sk2))
        _ = try store.perform(AddPatient(triage: .ungesichtet))
        try store.perform(SetDestination(patientID: sk1.id, hospital: HospitalSnapshot(name: "Klinik Nah")))
        _ = try store.perform(AddTemporaryUnit(callsign: "RK 1", type: .rtw))
        _ = try store.perform(AddPlaceholder(type: .ktw))
        fixture.clock.advance(95 * 60)

        let text = SituationSnapshot.text(store.state, openItemCount: 2, now: fixture.clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("Lagebild "))
        #expect(lines[0].hasSuffix("Laufzeit 1:35 h"))
        #expect(lines.contains("Patienten: 4 – vor Ort SK 1: 1 · SK 2: 2 · ungesichtet: 1"))
        #expect(lines.contains("Transporte: Zielklinik zugewiesen 1"))
        #expect(lines.contains("Einheiten: 1 vor Ort · 1 angefordert"))
        #expect(lines.contains("Offene Punkte: 2"))
        #expect(!text.contains("Mustermann"))
    }

    @Test func onlyCommanderSnapshotsSharedMission() throws {
        let store = try fixture.newMission()
        let other = UserID()
        #expect(SituationSnapshot.isResponsible(store.state.mission, userID: other), "nicht geteilt: eigenes Gerät")
        var mission = store.state.mission
        mission.commanderID = fixture.userA
        mission.participants = [MissionParticipant(userID: other, displayName: "Helfer", joinedAt: fixture.clock.now)]
        #expect(SituationSnapshot.isResponsible(mission, userID: fixture.userA))
        #expect(!SituationSnapshot.isResponsible(mission, userID: other))
    }
}
