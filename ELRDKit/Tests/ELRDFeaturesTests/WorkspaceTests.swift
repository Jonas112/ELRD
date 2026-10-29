import Foundation
import SwiftUI
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDStore

@Suite("Arbeitsbereich")
@MainActor
struct WorkspaceTests {
    @Test func sectionsHaveUniqueShortcutsAndTitles() {
        let shortcuts = WorkspaceSection.allCases.map { String($0.shortcut.character) }
        #expect(shortcuts == ["1", "2", "3", "4", "5", "6", "7"])
        #expect(Set(WorkspaceSection.allCases.map(\.title)).count == WorkspaceSection.allCases.count)
        #expect(WorkspaceSection.allCases.first == .overview)
    }

    @Test func badgesCountOpenPatientsAndUnreadMessages() throws {
        let store = try PreviewData.makeStore()
        let badges = WorkspaceBadges(state: store.state)
        #expect(badges.openPatients == 7)
        #expect(badges.badge(for: .patients) == 7)
        #expect(badges.badge(for: .messages) == 0)
        #expect(badges.badge(for: .map) == 0)
    }

    static let elapsedCases: [(seconds: Double, expected: String)] = [
        (0, "0:00 h"), (59, "0:00 h"), (2_700, "0:45 h"), (7_500, "2:05 h"), (93_900, "1 T 2:05 h"),
    ]

    @Test(arguments: WorkspaceTests.elapsedCases)
    func elapsedTime(seconds: Double, expected: String) {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ElapsedTimeFormat.string(from: start, to: start.addingTimeInterval(seconds)) == expected)
    }

    @Test func elapsedTimeNeverNegative() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(ElapsedTimeFormat.string(from: start, to: start.addingTimeInterval(-500)) == "0:00 h")
    }

    @Test func triageSummaryAlwaysShowsSK1to3() {
        let empty = TriageSummaryView(counts: [:])
        #expect(empty.visibleCategories == [.sk1, .sk2, .sk3])
        let withDead = TriageSummaryView(counts: [.verstorben: 1])
        #expect(withDead.visibleCategories == [.sk1, .sk2, .sk3, .verstorben])
        #expect(TriageSummaryView(counts: [:], showsEmpty: true).visibleCategories.count == 6)
    }

    @Test func viewsCanBeBuilt() throws {
        // Grobe Rauchprobe: Körper der Ansichten lassen sich erzeugen.
        let store = try PreviewData.makeStore()
        _ = MissionWorkspaceView(store: store).body
        _ = RootView().body
        _ = TriageBadge(.sk1).body
    }
}
