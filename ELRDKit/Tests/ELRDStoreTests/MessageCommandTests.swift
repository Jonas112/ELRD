import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Nachrichten")
@MainActor
struct MessageCommandTests {
    @Test func sentMessageIsReadForSenderAndLogged() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let message = try store.perform(SendMessage("  Landeplatz freihalten ", kind: .warning))
        #expect(message.text == "Landeplatz freihalten")
        #expect(message.kind == .warning)
        #expect(message.isAcknowledged, "eigene Nachricht gilt als gelesen")
        #expect(store.state.unreadMessageCount == 0)
        #expect(store.state.visibleLog.last?.message == "Warnung gesendet")
        #expect(throws: CommandError.invalid("Bitte einen Text eingeben.")) {
            try store.perform(SendMessage("   "))
        }
        let system = try store.perform(SendMessage("x", kind: .system))
        #expect(system.kind == .info, "Systemhinweise erzeugt nur die App")
    }

    @Test func acknowledgingWorksOnClosedMission() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        try store.perform(CloseMission())
        try store.perform(AcknowledgeMessages())
        #expect(throws: CommandError.notFound(.message)) {
            try store.perform(AcknowledgeMessages(MessageID()))
        }
    }
}
