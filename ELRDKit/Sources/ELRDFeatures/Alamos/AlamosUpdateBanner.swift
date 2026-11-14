import SwiftUI
import ELRDDomain
import ELRDStore

/// Hinweis im Einsatz auf einen neuen Stand aus Alamos FE2 (Schritt 143, E129).
///
/// Jede Art von Änderung ist eine eigene Meldung. „Ansehen und übernehmen“ öffnet die
/// Vorschau mit Auswahl; „Ausblenden“ lässt den Einsatz bis zum nächsten Stand unverändert.
struct AlamosUpdateBanner: View {
    let update: AlarmUpdate
    let canEdit: Bool
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Alamos FE2: \(update.changes.entries.count == 1 ? "1 neue Meldung" : "\(update.changes.entries.count) neue Meldungen") (Stand \(update.alarm.revision))")
                    .font(.headline)
                Spacer(minLength: Spacing.s)
                Text(update.alarm.updatedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: Spacing.m) {
                    messages
                    Spacer(minLength: Spacing.m)
                    buttons
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    messages
                    HStack(spacing: Spacing.s) {
                        Spacer(minLength: 0)
                        buttons
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    /// Eine Zeile je Meldung.
    private var messages: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(update.changes.entries) { entry in
                Label(entry.text, systemImage: entry.systemImage)
                    .font(.subheadline)
                    .lineLimit(2)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xxs)
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            Button("Ausblenden", action: onDismiss)
                .buttonStyle(.bordered)
            Button("Ansehen und übernehmen …", action: onReview)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .font(.headline)
        .controlSize(.large)
        .disabled(!canEdit)
    }
}
