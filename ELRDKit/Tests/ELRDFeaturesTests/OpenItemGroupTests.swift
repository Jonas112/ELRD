import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures

@Suite("Lage-Cockpit: offene Punkte gruppieren (Schritt 129)")
struct OpenItemGroupTests {
    private func item(_ id: String, _ kind: OpenItem.Kind, _ triage: Sichtungskategorie? = nil) -> OpenItem {
        OpenItem(id: id, kind: kind, triage: triage, title: id, detail: "", actionTitle: "Öffnen", target: .section(.patients))
    }

    @Test func groupsFromThresholdButNeverSK1() {
        let items = [
            item("a", .criticalWithoutTransport, .sk1), item("b", .criticalWithoutTransport, .sk1), item("c", .criticalWithoutTransport, .sk1),
            item("d", .urgentWithoutTransport, .sk2), item("e", .urgentWithoutTransport, .sk2),
            item("f", .longWait, .sk3), item("g", .longWait, .sk3), item("h", .longWait, .sk3), item("i", .longWait, .sk3),
            item("j", .placeholderUnits),
        ]
        let entries = OpenItem.grouped(items)
        #expect(entries.map(\.id) == ["a", "b", "c", "d", "e", "group-longWait", "j"])
        guard case .group(let group) = entries[5] else {
            Issue.record("Gruppe erwartet")
            return
        }
        #expect(group.count == 4)
        #expect(group.title == "4 Patienten SK 3 warten auf ein Transportmittel")
        #expect(group.detail(numbers: ["A-6", "A-7", "A-8", "A-9", "A-10", "A-11"]) == "A-6, A-7, A-8, A-9, A-10 … (+1)")
    }
}
