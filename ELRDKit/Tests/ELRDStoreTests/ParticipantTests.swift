import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDStore

@Suite("Teilnehmer und Rechte (Schritt 89)")
@MainActor
struct ParticipantTests {
    let fixture: StoreFixture
    let helperID = UserID()

    init() throws {
        fixture = try StoreFixture()
    }

    /// Zweite Person auf einem anderen Gerät (gleiche Datenbank, wie nach dem Abgleich).
    private func helperStore(_ missionID: MissionID) throws -> MissionStore {
        let clock = fixture.clock
        return try MissionStore(
            missionID: missionID,
            repository: fixture.repository,
            session: SessionIdentity(userID: helperID, displayName: "Max Helfer", device: fixture.deviceB),
            clock: try DeviceClock(deviceID: fixture.deviceB.deviceID, repository: fixture.repository),
            now: { clock.now }
        )
    }

    @Test func helperJoinsChoosesSectionAndAddsThere() throws {
        let lead = try fixture.newMission()
        let helper = try helperStore(lead.missionID)
        try helper.perform(JoinAsParticipant())
        try helper.perform(JoinAsParticipant())
        #expect(helper.state.mission.participants?.count == 1, "zweimal beitreten bleibt ein Eintrag")

        let section = try #require(helper.state.activeSections.last)
        try helper.perform(ChooseOwnSection(section.id))
        let patient = try helper.perform(AddPatient(triage: .sk2))
        #expect(patient.sectionID == section.id, "neuer Patient im eigenen Abschnitt")
        let unit = try helper.perform(AddTemporaryUnit(callsign: "RK 7", type: .rtw))
        #expect(unit.sectionID == section.id)
    }

    @Test func ownSectionPermissionLimitsEditing() throws {
        let lead = try fixture.newMission()
        let helper = try helperStore(lead.missionID)
        try helper.perform(JoinAsParticipant())
        let sections = helper.state.activeSections
        let mine = try #require(sections.last)
        let other = try #require(sections.first)
        try helper.perform(ChooseOwnSection(mine.id))

        try lead.reload()
        let foreign = try lead.perform(AddPatient(triage: .sk3, sectionID: other.id))
        #expect(throws: CommandError.self, "nur die Einsatzleitung vergibt Rechte") {
            try helper.perform(SetParticipantPermission(participantID: helperID.rawValue, permission: .full))
        }
        try lead.perform(SetParticipantPermission(participantID: helperID.rawValue, permission: .ownSection))

        try helper.reload()
        #expect(throws: CommandError.self) { try helper.perform(SetTriage(patientID: foreign.id, triage: .sk1)) }
        let own = try helper.perform(AddPatient(triage: .sk3))
        try helper.perform(SetTriage(patientID: own.id, triage: .sk2))
        try helper.perform(AddJournalText("Abschnitt eingerichtet"))
        #expect(throws: CommandError.self, "Einsatzdaten nicht") {
            try helper.perform(EditMission { $0.reason = "geändert" })
        }
    }

    @Test func readOnlyAllowsNothingButOwnEntry() throws {
        let lead = try fixture.newMission()
        let helper = try helperStore(lead.missionID)
        try helper.perform(JoinAsParticipant())
        try lead.reload()
        try lead.perform(SetParticipantPermission(participantID: helperID.rawValue, permission: .readOnly))
        try helper.reload()
        #expect(throws: CommandError.self) { try helper.perform(AddPatient(triage: .sk1)) }
        #expect(throws: CommandError.self) { try helper.perform(AddJournalText("Test")) }
        let section = try #require(helper.state.activeSections.first)
        try helper.perform(ChooseOwnSection(section.id))
        #expect(helper.state.mission.participant(helperID)?.permission == .readOnly, "eigene Rechte unverändert")
    }

    @Test func localMissionsStayUnrestricted() throws {
        let store = try fixture.newMission()
        #expect(store.state.mission.permission(of: UserID()) == .full)
        try store.perform(AddPatient(triage: .sk1))
    }

    @Test func participantDecodesUnknownPermissionAsReadOnly() throws {
        let json = #"{"id":"\#(UUID().uuidString)","displayName":"X","permission":"neu","joinedAt":0}"#
        let decoded = try JSONDecoder().decode(MissionParticipant.self, from: Data(json.utf8))
        #expect(decoded.permission == .readOnly)
    }
}
