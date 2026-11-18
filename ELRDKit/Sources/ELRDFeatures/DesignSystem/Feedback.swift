import SwiftUI
import UIKit
import Observation

// MARK: - Rückgängig und Haptik (Schritt 133)

/// Kurzer Hinweis unten mit „Rückgängig“ nach schnellen Aktionen (Patient angelegt,
/// SK geändert, Einheit verschoben oder zugeordnet). Statt Rückfragen: erst tun,
/// dann 6 s lang zurücknehmen können.
@MainActor
@Observable
public final class UndoCenter {
    public struct Item: Identifiable {
        public let id = UUID()
        public let text: String
        public let color: Color
        let undo: () throws -> Void
        /// Optional „Öffnen“ (z. B. neuen Patienten).
        let open: (() -> Void)?
    }

    public private(set) var current: Item?
    /// Fehler beim Zurücknehmen (z. B. inzwischen geändert).
    public var errorMessage: String?

    public init() {}

    public func offer(_ text: String, color: Color = .accentColor, open: (() -> Void)? = nil, undo: @escaping () throws -> Void) {
        current = Item(text: text, color: color, undo: undo, open: open)
    }

    public func performUndo() {
        guard let item = current else { return }
        current = nil
        do {
            try item.undo()
            Haptics.tap()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func performOpen() {
        guard let item = current else { return }
        current = nil
        item.open?()
    }

    public func dismiss(_ id: UUID) {
        if current?.id == id { current = nil }
    }
}

private struct UndoCenterKey: EnvironmentKey {
    static let defaultValue: UndoCenter? = nil
}

public extension EnvironmentValues {
    /// Im Arbeitsbereich gesetzt; außerhalb `nil` (dann kein Rückgängig-Hinweis).
    var undoCenter: UndoCenter? {
        get { self[UndoCenterKey.self] }
        set { self[UndoCenterKey.self] = newValue }
    }
}

/// Spürbare Rückmeldung bei wichtigen Aktionen.
@MainActor
public enum Haptics {
    /// Patient angelegt, SK geändert.
    public static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Zuordnen, Verschieben, Abhaken.
    public static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Aktion abgelehnt.
    public static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// Bestätigung als Leiste unten (Schritt 150, HIG `feedback.md`): für Informationen
/// ohne nötige Entscheidung statt eines Hinweisfensters. Verschwinden lässt sie der
/// Aufrufer (z. B. nach einigen Sekunden); VoiceOver liest sie beim Erscheinen vor.
struct NoticeBar: View {
    let title: String
    let message: String
    var systemImage = "checkmark.circle.fill"
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(StatusText.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: Spacing.s)
            Button("OK", action: onDismiss)
                .font(.headline)
                .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.comfortable)
                .hoverEffect(.highlight)
        }
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement("\(title). \(message)").post()
        }
    }
}
