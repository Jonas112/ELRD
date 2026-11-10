import Foundation
import Testing
@testable import ELRDCloud
@testable import ELRDDomain
@testable import ELRDStore

@Suite("Beitritt mit Genehmigung (Schritt 116)")
@MainActor
struct JoinApprovalTests {
    let server = FakeCloudServer()
    let clock = CloudTestClock()

    private func device(_ prefix: String, _ account: String) throws -> CloudDevice {
        try CloudDevice(prefix: prefix, account: account, server: server, clock: clock)
    }

    @Test func sealHidesNameAndOpensOnlyWithLink() throws {
        let url = URL(string: "https://www.icloud.com/share/0abc")!
        let other = URL(string: "https://www.icloud.com/share/0xyz")!
        let payload = JoinRequestPayload(userID: "_user1", displayName: "Max Muster", requestedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let sealed = try JoinSeal.seal(payload, url: url)
        #expect(String(decoding: sealed, as: UTF8.self).contains("Max") == false, "Name nicht im Klartext")
        #expect(try JoinSeal.open(sealed, url: url) == payload)
        #expect(throws: (any Error).self) { try JoinSeal.open(sealed, url: other) }
        #expect(JoinSeal.shareKey(for: url) != JoinSeal.shareKey(for: other))
        #expect(!JoinSeal.shareKey(for: url).contains("icloud"))
        let name = JoinSeal.requestName(shareKey: JoinSeal.shareKey(for: url), userID: "_user1")
        #expect(name == JoinSeal.requestName(shareKey: JoinSeal.shareKey(for: url), userID: "_user1"), "fest: erneutes Anfragen überschreibt")
        #expect(JoinSeal.decisionName(requestName: name).hasPrefix("decision-"))
    }

    @Test func approvedGuestJoinsOnlyAfterApproval() async throws {
        let owner = try device("A", "alice")
        let guest = try device("B", "bob")
        owner.coordinator.requiresJoinApproval = true
        let store = try owner.createMission()
        let patient = try store.perform(AddPatient(triage: .sk1))
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        await owner.coordinator.syncNow(store.missionID)

        // Ohne Zulassung: kein Beitritt, keine Daten.
        await #expect(throws: CloudShareError.approvalRequired) { _ = try await guest.coordinator.join(url) }
        #expect(guest.coordinator.link(for: store.missionID) == nil)

        try await guest.coordinator.requestJoin(url, displayName: "Bob Beispiel")
        #expect(guest.coordinator.pendingJoins.count == 1)
        await guest.coordinator.checkJoinRequests()
        #expect(guest.coordinator.link(for: store.missionID) == nil, "noch nicht entschieden")

        await owner.coordinator.checkJoinRequests()
        let request = try #require(owner.coordinator.joinRequests.first)
        #expect(request.payload.displayName == "Bob Beispiel")
        #expect(request.mission == store.missionID)
        try await owner.coordinator.decide(request, approve: true)
        #expect(owner.coordinator.joinRequests.isEmpty)
        await owner.coordinator.checkJoinRequests()
        #expect(owner.coordinator.joinRequests.isEmpty, "entschiedene Anfrage taucht nicht wieder auf")

        var approved: MissionID?
        guest.coordinator.onJoinApproved = { approved = $0 }
        await guest.coordinator.checkJoinRequests()
        #expect(approved == store.missionID)
        #expect(guest.coordinator.pendingJoins.isEmpty)
        #expect(await server.hasJoinRequest(request.id) == false, "Anfrage zurückgezogen")
        let copy = try guest.open(store.missionID)
        #expect(copy.state.activePatients.map(\.id) == [patient.id])
    }

    @Test func deniedGuestStaysOutside() async throws {
        let owner = try device("A", "alice")
        let guest = try device("B", "bob")
        owner.coordinator.requiresJoinApproval = true
        let store = try owner.createMission()
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        try await guest.coordinator.requestJoin(url, displayName: "Unbekannt")
        await owner.coordinator.checkJoinRequests()
        let request = try #require(owner.coordinator.joinRequests.first)
        try await owner.coordinator.decide(request, approve: false)

        await guest.coordinator.checkJoinRequests()
        #expect(guest.coordinator.pendingJoins.first?.status == .denied)
        #expect(guest.coordinator.link(for: store.missionID) == nil)
        await #expect(throws: CloudShareError.approvalRequired) { _ = try await guest.coordinator.join(url) }

        if let pending = guest.coordinator.pendingJoins.first { await guest.coordinator.cancelJoinRequest(pending) }
        #expect(guest.coordinator.pendingJoins.isEmpty)
    }

    @Test func withoutApprovalSettingLinkWorksAsBefore() async throws {
        let owner = try device("A", "alice")
        let guest = try device("B", "bob")
        let store = try owner.createMission()
        let url = try await owner.coordinator.startSharing(store.missionID, title: "MANV")
        await owner.coordinator.syncNow(store.missionID)
        #expect(try await guest.coordinator.join(url) == store.missionID)
    }
}
