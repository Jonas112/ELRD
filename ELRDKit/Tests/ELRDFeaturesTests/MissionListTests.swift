import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDPersistence
import ELRDEntitlements
import ELRDStore

@Suite("Einsatzliste und neuer Einsatz")
@MainActor
struct MissionListTests {
    let repository = InMemoryRepository()
    let device = DeviceIdentity(deviceID: DeviceID(), numberPrefix: "A")!

    func makeModel(
        entitlements: StaticEntitlements = .development(),
        sections: [MasterSection] = []
    ) throws -> MissionListModel {
        MissionListModel(
            repository: repository,
            session: SessionIdentity(userID: UserID(), displayName: "Erika Beispiel", device: device),
            clock: try DeviceClock(deviceID: device.deviceID, repository: repository),
            entitlements: entitlements,
            automaticSections: { sections }
        )
    }

    @Test func formBuildsTrimmedRequest() {
        var form = NewMissionForm()
        form.reason = "  VU mit mehreren Pkw \n"
        form.location = " B 19 "
        form.dispatchNumber = "   "
        form.type = .verkehrsunfall
        form.alarmstichwort = .rd2

        let sections = [
            MasterSection(name: "Behandlungsplatz", sortIndex: 2, addAutomatically: true),
            MasterSection(name: "Bereitstellungsraum", sortIndex: 1, addAutomatically: true, isInitial: true),
        ]
        let request = form.request(automaticSections: sections)
        #expect(request.reason == "VU mit mehreren Pkw")
        #expect(request.location == "B 19")
        #expect(request.dispatchNumber == nil, "leere ILS-Nummer wird nicht gespeichert")
        #expect(request.sectionNames == ["Bereitstellungsraum", "Behandlungsplatz"])
        #expect(request.initialSectionName == "Bereitstellungsraum")
        #expect(request.alarmstichwort == .rd2)
    }

    @Test func typeOrderCoversAllMissionTypes() {
        #expect(Set(NewMissionForm.typeOrder) == Set(MissionType.allCases))
        #expect(NewMissionForm.typeOrder.count == MissionType.allCases.count)
    }

    @Test func createOpensRunningMissionAndUpdatesList() throws {
        let model = try makeModel(sections: [MasterSection(name: "Bereitstellungsraum", sortIndex: 1, addAutomatically: true, isInitial: true)])
        #expect(model.missions.isEmpty)

        var form = NewMissionForm()
        form.reason = "Brand Wohnhaus"
        form.alarmstichwort = .rd3
        let store = try model.create(form)

        #expect(store.state.mission.title == "Brand Wohnhaus")
        #expect(store.state.activeUnits.count == 3)
        #expect(store.state.activeSections.map(\.name) == ["Bereitstellungsraum"])
        #expect(model.result.running.map(\.id) == [store.missionID])

        // Beendet: wandert in „Frühere Einsätze“.
        try store.perform(CloseMission())
        model.reload()
        #expect(model.result.running.isEmpty)
        #expect(model.result.finished.map(\.id) == [store.missionID])

        // Gelöscht: verschwindet ganz.
        try model.delete(store.missionID)
        #expect(model.missions.isEmpty)
    }

    @Test func withoutSubscriptionNothingCanBeCreated() throws {
        let model = try makeModel(entitlements: StaticEntitlements(state: .expired(since: nil)))
        #expect(!model.canCreate)
        #expect(throws: FeatureLockedError.self) { try model.create(NewMissionForm()) }
    }
}
