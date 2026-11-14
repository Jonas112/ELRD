import SwiftUI
import ELRDDomain
import ELRDStore

/// Hinweis im Einsatz auf einen neuen Stand aus Alamos FE2 (Schritt 143/145, E129).
///
/// Listet die Ereignisse einzeln (jedes Fahrzeug, jeder Patient, jede Alarmtext-Zeile,
/// Stichwort, Ort) – jedes einzeln übernehmbar oder verwerfbar. Bei vielen Ereignissen
/// zeigt er die ersten; „Alle anzeigen“ öffnet die vollständige Liste.
struct AlamosUpdateBanner: View {
    let update: AlarmUpdate
    let canEdit: Bool
    let onApply: (AlarmUpdateSelection) -> Void
    let onDiscard: (AlarmUpdateSelection) -> Void
    let onReview: () -> Void
    let onDismiss: () -> Void

    /// So viele Ereignisse direkt im Hinweis, damit der Arbeitsbereich sichtbar bleibt.
    static let visibleEvents = 4

    var body: some View {
        let events = update.events
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Alamos FE2: \(events.count == 1 ? "1 Änderung" : "\(events.count) Änderungen") (Stand \(update.alarm.revision))")
                    .font(.headline)
                Spacer(minLength: Spacing.s)
                Text(update.alarm.updatedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Spacing.xs) {
                ForEach(events.prefix(Self.visibleEvents)) { event in
                    AlamosEventRow(
                        event: event,
                        detail: AlamosEventRow.detail(for: event, in: update),
                        canEdit: canEdit,
                        compact: true,
                        onApply: { onApply(AlarmUpdateSelection(events: [event])) },
                        onDiscard: { onDiscard(AlarmUpdateSelection(events: [event])) }
                    )
                }
            }
            HStack(spacing: Spacing.s) {
                if events.count > Self.visibleEvents {
                    Text("+ \(events.count - Self.visibleEvents) weitere")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Ausblenden", action: onDismiss)
                    .buttonStyle(.bordered)
                Button("Alle anzeigen …", action: onReview)
                    .buttonStyle(.bordered)
                Button("Alles übernehmen (\(events.count))") { onApply(update.fullSelection) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!canEdit)
            }
            .font(.headline)
            .controlSize(.large)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// Ein Ereignis aus Alamos FE2 mit „Übernehmen“ und „Verwerfen“ (Schritt 145).
struct AlamosEventRow: View {
    let event: AlamosChanges.Event
    let detail: String?
    let canEdit: Bool
    var compact = false
    let onApply: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Image(systemName: event.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(event.title)
                    .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                    .lineLimit(compact ? 1 : 3)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 4)
                }
            }
            Spacer(minLength: Spacing.s)
            Button(action: onDiscard) {
                Label("Verwerfen", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(event.title) verwerfen")
            Button("Übernehmen", action: onApply)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityLabel("\(event.title) übernehmen")
        }
        .controlSize(compact ? .regular : .large)
        .disabled(!canEdit)
        .padding(.horizontal, compact ? Spacing.s : 0)
        .padding(.vertical, compact ? Spacing.xxs : Spacing.xs)
        .background(compact ? AnyShapeStyle(Surface.elevated) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .frame(minHeight: TouchTarget.minimum)
    }

    /// Zusatzzeile: Fahrzeugtyp und Herkunft, beim Patienten Name, Bemerkung und Ziel.
    static func detail(for event: AlamosChanges.Event, in update: AlarmUpdate) -> String? {
        switch event.kind {
        case .keyword, .address:
            return "Wird im Tagebuch vermerkt, der Einsatz bleibt unverändert."
        case .message:
            return nil
        case .vehicle:
            guard let match = update.vehicle(for: event) else { return nil }
            return "\(match.type.shortName) · \(match.master != nil ? "aus den Stammdaten" : "temporär, Typ geschätzt")"
        case .patient:
            guard let patient = update.patient(for: event) else { return nil }
            let parts = [patient.name, patient.remark, patient.destination.map { "Ziel: \($0)" }].compactMap { $0 }
            return parts.isEmpty ? "Wird ungesichtet angelegt." : parts.joined(separator: " · ")
        }
    }
}
