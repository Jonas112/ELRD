import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Protokoll filtern")
@MainActor
struct ProtocolFilterTests {
    @Test func filtersByCategoryAndWords() throws {
        let store = try PreviewData.makeStore() // RD 3, 7 Patienten, 1 Texteintrag
        let entries = store.state.visibleLog
        let counts = ProtocolFilter.counts(entries, search: "")
        #expect((counts[.patient] ?? 0) >= 7)
        #expect((counts[.unit] ?? 0) >= 1)

        let patients = ProtocolFilter(category: .patient).apply(to: entries)
        #expect(patients.allSatisfy { $0.category == .patient })
        let alarm = ProtocolFilter(search: "alarmstichwort rd").apply(to: entries)
        #expect(alarm.count == 1, "Groß/klein egal, alle Wörter")
        #expect(ProtocolFilter(category: .map, search: "").apply(to: entries).isEmpty)
    }
}
