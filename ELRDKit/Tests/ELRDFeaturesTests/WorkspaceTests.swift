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
        #expect(shortcuts == ["1", "2", "3", "4", "5"], "fünf Bereiche (E55)")
        #expect(Set(WorkspaceSection.allCases.map(\.title)).count == WorkspaceSection.allCases.count)
        #expect(WorkspaceSection.allCases.first == .overview)
    }

    @Test func badgesCountOpenPatientsAndUnreadMessages() throws {
        let store = try PreviewData.makeStore()
        let badges = WorkspaceBadges(state: store.state)
        #expect(badges.openPatients == 7)
        #expect(badges.badge(for: .patients) == 7)
        #expect(badges.unreadMessages == 0)
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

    @Test func extremeTriageColorsGetOutline() {
        #expect(TriageBadge.needsOutline(.verstorben))
        #expect(TriageBadge.needsOutline(.unverletzt))
        #expect(!TriageBadge.needsOutline(.sk1))
    }

    @Test(arguments: [(744.0, WorkspaceLayout.bottomBar), (799, .bottomBar), (800, .rail), (1133, .rail), (1376, .rail)] as [(Double, WorkspaceLayout)])
    func layoutDependsOnWidth(width: Double, expected: WorkspaceLayout) {
        #expect(WorkspaceLayout.forWidth(width) == expected)
    }

    @Test func openItemsListMostUrgentFirst() throws {
        // Beispiel: RD 3 (3 Platzhalter), SK 1, SK 2 ×2, SK 3 ×3, ungesichtet – alle ohne Einheit.
        let store = try PreviewData.makeStore()
        let items = OpenItem.items(for: store.state, now: Date())
        #expect(items.map(\.kind) == [
            .criticalWithoutTransport, .notTriaged, .urgentWithoutTransport, .urgentWithoutTransport, .placeholderUnits,
        ])
        #expect(items.first?.title == "A-1 hat kein Transportmittel")
        #expect(items.first?.target == .patient(store.state.activePatients[0].id), "führt direkt zum Patienten")
        #expect(items.last?.title == "3 Platzhalter ohne Fahrzeug")
        #expect(items.last?.detail == "2 RTW, 1 NEF")
        #expect(items.last?.target == .section(.organisation))
    }

    @Test func statusCountsSkipDeletedPatients() throws {
        let store = try PreviewData.makeStore()
        let first = try #require(store.state.activePatients.first)
        try store.perform(DeletePatient(patientID: first.id))
        let counts = PatientStatusCounts(patients: store.state.patients)
        #expect(counts.waiting == 6)
        #expect(counts.assigned + counts.inTransport + counts.released == 0)
    }

    @Test func undoQuickAddKeepsNumberReserved() throws {
        let store = try PreviewData.makeStore()
        let added = try store.perform(AddPatient(triage: .sk2))
        #expect(added.number.description == "A-8")
        try store.perform(DeletePatient(patientID: added.id))
        #expect(store.state.activePatients.count == 7)
        let next = try store.perform(AddPatient(triage: .sk2))
        #expect(next.number.description == "A-9", "gelöschte Nummer wird nicht erneut vergeben")
        #expect(throws: CommandError.notFound(.patient)) { try store.perform(DeletePatient(patientID: added.id)) }
    }

    @Test func accountInitials() {
        #expect(AccountMenuModel(displayName: "Erika Beispiel", detail: "", signOut: {}).initials == "EB")
        #expect(AccountMenuModel(displayName: "ELRD", detail: "", signOut: {}).initials == "E")
        #expect(AccountMenuModel(displayName: " ", detail: "", signOut: {}).initials == "?")
    }

    @Test func viewsCanBeBuilt() throws {
        // Grobe Rauchprobe: Körper der Ansichten lassen sich erzeugen.
        let store = try PreviewData.makeStore()
        _ = MissionWorkspaceView(store: store).body
        _ = RootView().body
        _ = TriageBadge(.sk1).body
    }
}
