import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereiche eines Einsatzes (Symbolleiste links bzw. unten).
///
/// Bewusst nur fünf (E55): Nachrichten sind die Glocke in der Leiste,
/// das Protokoll wird ein Filter im Tagebuch.
public enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case patients
    case organisation
    case map
    case journal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Lage"
        case .patients: "Patienten"
        case .organisation: "Einheiten"
        case .map: "Karte"
        case .journal: "Tagebuch"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .patients: "person.2"
        case .organisation: "box.truck"
        case .map: "map"
        case .journal: "book.pages"
        }
    }

    /// Tastaturkürzel ⌘1 … ⌘5.
    public var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1)))
    }
}

/// Zahlen an den Bereichen und an der Glocke.
public struct WorkspaceBadges: Equatable, Sendable {
    /// Patienten, deren Versorgung noch nicht abgeschlossen ist.
    public let openPatients: Int
    public let unreadMessages: Int

    public init(state: MissionState) {
        openPatients = state.patients.active.filter { $0.status != .released && $0.status != .inTransport }.count
        unreadMessages = state.unreadMessageCount
    }

    public func badge(for section: WorkspaceSection) -> Int {
        section == .patients ? openPatients : 0
    }
}

/// Anordnung des Arbeitsbereichs je nach verfügbarer Breite.
public enum WorkspaceLayout: Equatable, Sendable {
    /// Symbolleiste links (iPad quer, große iPads hoch).
    case rail
    /// Leiste unten (iPad mini hoch, schmale Fenster in Split View/Stage Manager).
    case bottomBar

    /// Ab 800 pt Breite links, darunter unten – dort liegt sie am Daumen.
    public static func forWidth(_ width: CGFloat) -> WorkspaceLayout {
        width < 800 ? .bottomBar : .rail
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

/// Aktionen des Arbeitsbereichs für das Menü (Schritt 52).
public struct WorkspaceActions {
    let newJournalEntry: () -> Void
    let openMessages: () -> Void
    let openReport: () -> Void
    let openDetails: () -> Void
}

public struct WorkspaceActionsKey: FocusedValueKey {
    public typealias Value = WorkspaceActions
}

public extension FocusedValues {
    /// Aktionen des Einsatzes im aktiven Fenster.
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

/// Menü „Einsatz“ (Hardware-Tastatur, Magic Keyboard): ⌘1 … ⌘5 für die Bereiche,
/// dazu Tagebuch, Nachrichten, Bericht und Einsatzdaten. ⌘ gedrückt halten zeigt
/// die Übersicht. Wirkt auf das jeweils aktive Fenster.
public struct WorkspaceCommands: Commands {
    @FocusedBinding(\.workspaceSelection) private var selection
    @FocusedValue(\.workspaceActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandMenu("Einsatz") {
            ForEach(WorkspaceSection.allCases) { section in
                Button(section.title) { selection = section }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .disabled(selection == nil)
            }
            Divider()
            Button("Tagebucheintrag schreiben") { actions?.newJournalEntry() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(actions == nil)
            Button("Nachrichten") { actions?.openMessages() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Bericht erstellen") { actions?.openReport() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)
            Button("Einsatzdaten") { actions?.openDetails() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
