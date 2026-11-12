import SwiftUI
import ELRDDomain
import ELRDStore

/// Einsatzliste: Einsätze aus Alamos FE2 (Schritt 140). Neue Einsätze stehen oben und
/// sind markiert; Tippen öffnet die Einzelheiten mit „Als Einsatz übernehmen“.
struct AlamosInboxCard: View {
    let inbox: AlamosInbox
    /// Bereits übernommene Einsätze: FE2-Einsatznummer → ELRD-Einsatz.
    let imported: [String: MissionSummary]
    let onSelect: (AlamosAlarm) -> Void

    @State private var showsAll = false
    private static let collapsedCount = 3

    var body: some View {
        let alarms = inbox.visibleAlarms
        VStack(alignment: .leading, spacing: Spacing.m) {
            header(count: alarms.filter { !$0.isClosed }.count)
            if alarms.isEmpty {
                Text(inbox.lastSuccess == nil && inbox.lastError == nil ? "Wird abgefragt …" : "Keine Einsätze aus Alamos FE2.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: Spacing.s) {
                    ForEach(showsAll ? alarms : Array(alarms.prefix(Self.collapsedCount))) { alarm in
                        Button { onSelect(alarm) } label: {
                            AlamosAlarmRow(alarm: alarm, isNew: inbox.isUnseen(alarm), imported: imported[alarm.externalId])
                        }
                        .buttonStyle(.plain)
                    }
                }
                if alarms.count > Self.collapsedCount {
                    Button(showsAll ? "Weniger zeigen" : "Alle \(alarms.count) zeigen") {
                        withAnimation { showsAll.toggle() }
                    }
                    .font(.callout.weight(.semibold))
                    .frame(minHeight: TouchTarget.minimum)
                }
            }
        }
        .cardStyle()
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.red.opacity(inbox.unseen.isEmpty ? 0 : 0.6), lineWidth: 2)
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Label("Alamos FE2", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            if count > 0 {
                StatusChip("\(count) offen", color: .red)
            }
            Spacer(minLength: Spacing.s)
            statusText
            Button {
                Task { await inbox.refresh() }
            } label: {
                if inbox.isRefreshing {
                    ProgressView().frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                }
            }
            .disabled(inbox.isDemo)
            .accessibilityLabel("Jetzt abfragen")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if let error = inbox.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if let last = inbox.lastSuccess {
            Text("Stand \(last.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Eine Zeile: Stichwort, Meldebild, Ort, Zeit, Fahrzeuge/Patienten, Marken.
struct AlamosAlarmRow: View {
    let alarm: AlamosAlarm
    let isNew: Bool
    let imported: MissionSummary?

    var body: some View {
        let data = alarm.data
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(data.keyword ?? "–")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.s)
                .frame(minWidth: 64, minHeight: 36)
                .background(alarm.isClosed ? Color.gray : Color.red, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    Text(data.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if isNew { StatusChip("Neu", color: .red) }
                    if alarm.isTest { StatusChip("Test", color: .purple) }
                    if alarm.isClosed { StatusChip("geschlossen", color: .gray) }
                }
                if let address = data.location?.addressLine, !address.isEmpty {
                    Text(address)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: Spacing.m) {
                    Text(alarm.receivedAt, format: .dateTime.hour().minute())
                    if !data.callsigns.isEmpty { Label("\(data.callsigns.count)", systemImage: "car.2") }
                    if !data.patients.isEmpty { Label("\(data.patients.count)", systemImage: "person.2") }
                    if alarm.revision > 1 { Text("Stand \(alarm.revision)") }
                    if let imported {
                        Label("übernommen: \(imported.displayNumber)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, Spacing.s)
        }
        .padding(Spacing.m)
        .frame(minHeight: TouchTarget.comfortable)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Einzelheiten und Übernahme")
    }
}
