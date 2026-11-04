import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Einsatzdaten")
@MainActor
struct MissionDetailsTests {
    @Test func unchangedFormChangesNothing() throws {
        let store = try PreviewData.makeStore()
        let form = MissionEditForm(mission: store.state.mission)
        #expect(!form.hasChanges)
        var mission = store.state.mission
        form.apply(to: &mission)
        #expect(mission == store.state.mission)
    }

    @Test func onlyEditedFieldsAreWrittenSoOtherChangesSurvive() throws {
        let store = try PreviewData.makeStore()
        var form = MissionEditForm(mission: store.state.mission)
        form.location = "  B 19, km 12  "
        form.dispatchNumber = "4711-26"

        // Inzwischen ändert jemand anderes den Einsatzgrund.
        try store.perform(EditMission { $0.reason = "VU, 3 Pkw, 1 eingeklemmt" })

        try store.perform(EditMission { form.apply(to: &$0) })
        let mission = store.state.mission
        #expect(mission.location == "B 19, km 12")
        #expect(mission.dispatchNumber == "4711-26")
        #expect(mission.reason == "VU, 3 Pkw, 1 eingeklemmt", "fremde Änderung bleibt erhalten")
    }

    @Test func clearingDispatchNumberStoresNil() throws {
        let store = try PreviewData.makeStore()
        try store.perform(EditMission { $0.dispatchNumber = "123" })
        var form = MissionEditForm(mission: store.state.mission)
        form.dispatchNumber = "   "
        try store.perform(EditMission { form.apply(to: &$0) })
        #expect(store.state.mission.dispatchNumber == nil)
    }

    static let kilometerCases: [(text: String, value: Int??)] = [
        ("", .some(nil)), ("  ", .some(nil)), ("12345", .some(12_345)), ("12.345", .some(12_345)), ("12 km", nil), ("-5", .some(-5)),
    ]

    @Test(arguments: MissionDetailsTests.kilometerCases)
    func kilometerParsing(text: String, value: Int??) {
        #expect(MissionEditForm.parseKilometers(text) == value)
    }

    @Test func problemsAreReportedBeforeSaving() throws {
        let store = try PreviewData.makeStore()
        let mission = store.state.mission
        var form = MissionEditForm(mission: mission)
        form.odometerStart = "1200"
        form.odometerEnd = "1100"
        #expect(form.problems(applyingTo: mission) == [.mission(.odometerEndBeforeStart)])

        form.odometerEnd = "viel"
        #expect(form.problems(applyingTo: mission) == [.odometerNotANumber])

        form.odometerEnd = "1250"
        #expect(form.problems(applyingTo: mission).isEmpty)
        try store.perform(EditMission { form.apply(to: &$0) })
        #expect(store.state.mission.distanceDriven == 50)
    }

    @Test func commanderCanBeChangedAndCleared() throws {
        let store = try PreviewData.makeStore()
        let other = UserID()
        var form = MissionEditForm(mission: store.state.mission)
        form.commanderID = other
        try store.perform(EditMission { form.apply(to: &$0) })
        #expect(store.state.mission.commanderID == other)

        var second = MissionEditForm(mission: store.state.mission)
        second.commanderID = nil
        try store.perform(EditMission { second.apply(to: &$0) })
        #expect(store.state.mission.commanderID == nil)
    }

    @Test func closedMissionIsReadOnlyUntilReopened() throws {
        let store = try PreviewData.makeStore()
        try store.perform(CloseMission())
        #expect(store.state.mission.isClosed)
        #expect(store.state.mission.endedAt != nil)
        #expect(throws: CommandError.missionClosed) { try store.perform(EditMission { $0.location = "x" }) }
        #expect(throws: CommandError.missionClosed) { try store.perform(AddPatient()) }

        try store.perform(ReopenMission())
        try store.perform(EditMission { $0.location = "Neuer Ort" })
        #expect(store.state.mission.location == "Neuer Ort")
        #expect(store.state.mission.endedAt != nil, "Einsatzende bleibt nach dem Wiederöffnen erhalten (wie ELRDRG)")
    }

    @Test func detailsViewCanBeBuilt() throws {
        let store = try PreviewData.makeStore()
        _ = MissionDetailsView(store: store, people: [PersonChoice(id: UserID(), name: "Erika Beispiel", detail: "ELRD 1")]).body
    }
}
