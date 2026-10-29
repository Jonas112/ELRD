import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereiche eines Einsatzes in der Seitenleiste.
public enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case patients
    case organisation
    case map
    case journal
    case messages
    case log

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Übersicht"
        case .patients: "Patienten"
        case .organisation: "Organisation"
        case .map: "Lagekarte"
        case .journal: "Tagebuch"
        case .messages: "Nachrichten"
        case .log: "Protokoll"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .patients: "cross.case"
        case .organisation: "rectangle.3.group"
        case .map: "map"
        case .journal: "book.pages"
        case .messages: "bubble.left.and.bubble.right"
        case .log: "list.bullet.rectangle"
        }
    }

    /// Tastaturkürzel ⌘1 … ⌘7.
    public var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1)))
    }

    /// Schritt im Plan, in dem der Bereich gebaut wird (für Platzhalter).
    var plannedStep: Int {
        switch self {
        case .overview: 37
        case .patients: 18
        case .organisation: 24
        case .map: 28
        case .journal: 33
        case .messages: 36
        case .log: 36
        }
    }
}

/// Zahlen neben den Bereichen in der Seitenleiste.
public struct WorkspaceBadges: Equatable, Sendable {
    /// Patienten, deren Versorgung noch nicht abgeschlossen ist.
    public let openPatients: Int
    public let unreadMessages: Int

    public init(state: MissionState) {
        openPatients = state.patients.active.filter { $0.status != .released && $0.status != .inTransport }.count
        unreadMessages = state.unreadMessageCount
    }

    public func badge(for section: WorkspaceSection) -> Int {
        switch section {
        case .patients: openPatients
        case .messages: unreadMessages
        default: 0
        }
    }
}

/// Laufzeit eines Einsatzes, z. B. „0:45 h“ oder „1 T 2:05 h“.
public enum ElapsedTimeFormat {
    public static func string(from start: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        let clock = "\(hours):\(minutes < 10 ? "0" : "")\(minutes) h"
        return days > 0 ? "\(days) T \(clock)" : clock
    }
}

// MARK: - Tastaturkürzel über das Menü

public struct WorkspaceSelectionKey: FocusedValueKey {
    public typealias Value = Binding<WorkspaceSection>
}

public extension FocusedValues {
    /// Ausgewählter Bereich des Einsatzes im aktiven Fenster.
    var workspaceSelection: Binding<WorkspaceSection>? {
        get { self[WorkspaceSelectionKey.self] }
        set { self[WorkspaceSelectionKey.self] = newValue }
    }
}

/// Menü „Einsatz“ mit ⌘1 … ⌘7 (Hardware-Tastatur, Magic Keyboard).
/// Wirkt auf das jeweils aktive Fenster.
public struct WorkspaceCommands: Commands {
    @FocusedBinding(\.workspaceSelection) private var selection

    public init() {}

    public var body: some Commands {
        CommandMenu("Einsatz") {
            ForEach(WorkspaceSection.allCases) { section in
                Button(section.title) { selection = section }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .disabled(selection == nil)
            }
        }
    }
}
