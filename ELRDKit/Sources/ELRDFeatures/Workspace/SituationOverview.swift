import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereich „Lage“ (Einsatz-Dashboard): offene Punkte (dringendste zuerst), Sichtung,
/// Patienten nach Stand, Transportmittel, Verteilung auf Kliniken, Tagebuch.
/// Jede Karte führt per Tipp in ihren Bereich.
struct SituationOverview: View {
    let store: MissionStore
    let onTarget: (OpenItem.Target) -> Void

    @State private var journalText = ""
    @State private var journalError: String?
    @FocusState private var journalFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let items = OpenItem.items(for: store.state, now: context.date)
            let dashboard = SituationDashboard(state: store.state)
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.xl) {
                        VStack(spacing: Spacing.xl) {
                            openItemsCard(items)
                            hospitalCard(dashboard)
                        }
                        .frame(minWidth: 520)
                        VStack(spacing: Spacing.xl) {
                            triageCard(dashboard)
                            statusCard
                            unitCard(dashboard)
                            journalCard
                        }
                        .frame(minWidth: 340, maxWidth: 460)
                    }
                    VStack(spacing: Spacing.l) {
                        openItemsCard(items)
                        triageCard(dashboard)
                        statusCard
                        unitCard(dashboard)
                        hospitalCard(dashboard)
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

    // MARK: Sichtung

    private func triageCard(_ dashboard: SituationDashboard) -> some View {
        Button { onTarget(.section(.patients)) } label: {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sichtung").font(.title2.weight(.bold)).foregroundStyle(.primary)
                    Spacer()
                    Text(dashboard.patientTotal == 1 ? "1 Patient" : "\(dashboard.patientTotal) Patienten")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TriageSummaryView(counts: dashboard.triageCounts, showsEmpty: true)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Öffnet die Patientenliste.")
    }

    // MARK: Transportmittel

    private func unitCard(_ dashboard: SituationDashboard) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transportmittel").font(.title2.weight(.bold))
                Spacer()
                Text("\(dashboard.unitTotal) Einheiten").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Grid(horizontalSpacing: Spacing.m, verticalSpacing: Spacing.m) {
                GridRow {
                    countTile(dashboard.freeTransport, "frei", target: .organisation, highlight: dashboard.freeTransport == 0 && dashboard.patientTotal > 0)
                    countTile(dashboard.busyTransport, "bei Patienten", target: .organisation)
                }
                if dashboard.placeholders > 0 {
                    GridRow {
                        countTile(dashboard.placeholders, dashboard.placeholders == 1 ? "Platzhalter ohne Fahrzeug" : "Platzhalter ohne Fahrzeug", target: .organisation)
                            .gridCellColumns(2)
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func countTile(_ count: Int, _ label: String, target: WorkspaceSection, highlight: Bool = false) -> some View {
        Button { onTarget(.section(target)) } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("\(count)")
                    .font(.system(size: 40, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(highlight ? Color.orange : Color.primary)
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

    // MARK: Kliniken

    @ViewBuilder
    private func hospitalCard(_ dashboard: SituationDashboard) -> some View {
        if !dashboard.hospitals.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Verteilung auf Kliniken").font(.title2.weight(.bold))
                    .padding(Spacing.xl)
                ForEach(dashboard.hospitals) { load in
                    Divider()
                    HStack(spacing: Spacing.m) {
                        Text(load.name).font(.headline).lineLimit(2)
                        Spacer(minLength: Spacing.m)
                        ForEach(TriageSummaryView.order.filter { (load.byTriage[$0] ?? 0) > 0 }, id: \.self) { triage in
                            Text("\(load.byTriage[triage] ?? 0)")
                                .font(.headline.weight(.heavy).monospacedDigit())
                                .foregroundStyle(Color.onTriage(triage))
                                .frame(minWidth: 40, minHeight: 32)
                                .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityLabel("\(load.byTriage[triage] ?? 0) \(triage.displayName)")
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.s)
                    .frame(minHeight: TouchTarget.comfortable)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.bottom, Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
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
                    .draftSync($journalText, field: .journal, mission: store.missionID)
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
            journalError = ErrorText.message(for: error)
        }
    }
}

/// Zeile „Offene Punkte“: Kennzeichen, Text, Knopf.
struct OpenItemRow: View {
    let item: OpenItem
    let action: () -> Void

    var body: some View {
        // iPhone: Knopf unter den Text statt daneben, sonst bricht er silbenweise um.
        ViewThatFits(in: .horizontal) {
            wide
            narrow
        }
    }

    private var wide: some View {
        HStack(spacing: Spacing.l) {
            marker
                .frame(width: 64, height: 44)
            texts(titleLines: 2)
                // Idealbreite fest, damit die Wahl nicht von der Textlänge abhängt.
                .frame(minWidth: 160, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
            actionButton
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.s)
    }

    private var narrow: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            marker
                .frame(width: 52, height: 40)
            VStack(alignment: .leading, spacing: Spacing.s) {
                texts(titleLines: 3)
                actionButton
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private func texts(titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(item.title)
                .font(.headline)
                .lineLimit(titleLines)
            Text(item.detail)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var actionButton: some View {
        Button(action: action) {
            Text(item.actionTitle)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.headline)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minHeight: TouchTarget.comfortable)
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
