import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereich „Lage“: offene Punkte (dringendste zuerst), Patienten nach Stand, Tagebuch.
///
/// Vollständiges Dashboard folgt in Schritt 37; die offenen Punkte sind schon echt.
struct SituationOverview: View {
    let store: MissionStore
    let onTarget: (OpenItem.Target) -> Void

    @State private var journalText = ""
    @State private var journalError: String?
    @FocusState private var journalFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let items = OpenItem.items(for: store.state, now: context.date)
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.xl) {
                        openItemsCard(items).frame(minWidth: 520)
                        VStack(spacing: Spacing.xl) {
                            statusCard
                            journalCard
                        }
                        .frame(minWidth: 340, maxWidth: 460)
                    }
                    VStack(spacing: Spacing.l) {
                        openItemsCard(items)
                        statusCard
                        journalCard
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Offene Punkte

    private func openItemsCard(_ items: [OpenItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Offene Punkte").font(.title2.weight(.bold))
                Spacer()
                if !items.isEmpty {
                    Text("dringendste zuerst").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.m)

            if items.isEmpty {
                Label("Nichts offen.", systemImage: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xl)
            } else {
                ForEach(items) { item in
                    Divider()
                    OpenItemRow(item: item) { onTarget(item.target) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Patienten nach Stand

    private var statusCard: some View {
        let counts = PatientStatusCounts(patients: store.state.patients)
        return VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Patienten").font(.title2.weight(.bold))
            Grid(horizontalSpacing: Spacing.m, verticalSpacing: Spacing.m) {
                GridRow {
                    statusTile(counts.waiting, "warten")
                    statusTile(counts.assigned, "Einheit zugeordnet")
                }
                GridRow {
                    statusTile(counts.inTransport, "im Transport")
                    statusTile(counts.released, "entlassen")
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func statusTile(_ count: Int, _ label: String) -> some View {
        Button { onTarget(.section(.patients)) } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("\(count)")
                    .font(.system(size: 40, weight: .heavy))
                    .monospacedDigit()
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding(.horizontal, Spacing.l)
            .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(label)")
    }

    // MARK: Tagebuch

    private var journalCard: some View {
        let latest = Array(store.state.chronologicalJournal.suffix(2).reversed())
        return VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tagebuch").font(.title2.weight(.bold))
                Spacer()
                Button("Alle") { onTarget(.section(.journal)) }
                    .font(.headline)
                    .frame(minHeight: TouchTarget.minimum)
            }
            ForEach(latest) { entry in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    Text(entry.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(entry.text).lineLimit(2)
                }
            }
            HStack(spacing: Spacing.s) {
                TextField("Eintrag schreiben …", text: $journalText, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($journalFocused)
                    .submitLabel(.send)
                    .onSubmit(addJournalEntry)
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: TouchTarget.comfortable)
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button(action: addJournalEntry) {
                    Image(systemName: "arrow.up")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: TouchTarget.comfortable, height: TouchTarget.comfortable)
                        .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(trimmedJournalText.isEmpty)
                .opacity(trimmedJournalText.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Eintragen")
            }
            if let journalError {
                Label(journalError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var trimmedJournalText: String {
        journalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addJournalEntry() {
        let text = trimmedJournalText
        guard !text.isEmpty else { return }
        do {
            try store.perform(AddJournalText(text))
            journalText = ""
            journalError = nil
        } catch {
            journalError = error.localizedDescription
        }
    }
}

/// Zeile „Offene Punkte“: Kennzeichen, Text, Knopf.
struct OpenItemRow: View {
    let item: OpenItem
    let action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.l) {
            marker
                .frame(width: 64, height: 44)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.m)
            Button(item.actionTitle, action: action)
                .font(.headline)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(minHeight: TouchTarget.comfortable)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.s)
    }

    @ViewBuilder private var marker: some View {
        if let triage = item.triage {
            Text(triage.shortName)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.onTriage(triage))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(triage.displayName)
        } else {
            Image(systemName: item.kind == .unreadMessages ? "bell" : "box.truck")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
