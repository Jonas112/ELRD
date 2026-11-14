import SwiftUI
import ELRDDomain
import ELRDStore

/// Hinweis im Einsatz auf einen neuen Stand aus Alamos FE2 (Schritt 143, E129).
///
/// Zeigt die Änderungen seit der letzten Übernahme. „Übernehmen“ ergänzt nur Neues
/// (Fahrzeuge, Patienten, Tagebuch); „Ausblenden“ lässt den Einsatz unverändert.
struct AlamosUpdateBanner: View {
    let update: AlarmUpdate
    let canEdit: Bool
    let onApply: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.m) {
                icon
                text
                Spacer(minLength: Spacing.m)
                buttons
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    icon
                    text
                }
                HStack(spacing: Spacing.s) {
                    Spacer(minLength: 0)
                    buttons
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

    private var icon: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Neuer Stand aus Alamos FE2 (Stand \(update.alarm.revision))")
                .font(.headline)
            ForEach(update.changes.summary, id: \.self) { line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if update.changes.keyword != nil || update.changes.address != nil {
                Text("Stichwort und Einsatzort werden nur im Tagebuch vermerkt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            Button("Ausblenden", action: onDismiss)
                .buttonStyle(.bordered)
            Button("Übernehmen", action: onApply)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .font(.headline)
        .controlSize(.large)
        .disabled(!canEdit)
    }
}
