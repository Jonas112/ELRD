import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDStore

@Suite("Lernpfad (Schritt 139)")
@MainActor
struct TutorialTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func stepsAreDetectedFromState() throws {
        let store = try PreviewData.makeStore(now: now)
        let state = store.state
        #expect(TutorialStep.all.count == 10)
        #expect(TutorialStep.all.map(\.id) == Array(1...10))
        let first = try #require(TutorialStep.all.first)
        #expect(first.isDone(state, TutorialProgress()) == !state.patients.active.isEmpty)
        let last = try #require(TutorialStep.all.last)
        #expect(!last.isDone(state, TutorialProgress()))
        #expect(last.isDone(state, TutorialProgress(openedReport: true)))
    }
}
