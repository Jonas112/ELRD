import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereich „Lage“ (Einsatz-Dashboard): offene Punkte (dringendste zuerst), Sichtung,
/// Patienten nach Stand, Transportmittel, Verteilung auf Kliniken, Tagebuch.
/// Jede Karte führt per Tipp in ihren Bereich.
struct SituationOverview: View {
    let store: MissionStore
    var people: [PersonChoice] = []
    var masterData: MasterDataEditor?
    let onTarget: (OpenItem.Target) -> Void

    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @State private var sheet: Tool? = SituationOverview.demoTool

    /// Bildschirmfotos: Werkzeug gleich geöffnet.
    private static var demoTool: Tool? {
        switch AppLaunchOptions.current.demoScreen {
        case .situationReport?: .report
        case .checklist?: .checklist
        case .leadership?: .leadership
        case .hospitals?, .distribution?: .hospitals
        case .handover?: .handover
        case .communicationPlan?, .communicationChart?: .communication
        default: nil
        }
    }
    @State private var journalText = ""
    @State private var journalError: String?
    /// Aufgeklappte Gruppen offener Punkte (Schritt 129).
    @State private var expandedGroups: Set<String> = []
    @FocusState private var journalFocused: Bool

    /// Werkzeuge der Lage (Schritte 67, 71, 73, 75, 76).
    enum Tool: String, Identifiable {
        case report, checklist, handover, hospitals, leadership, phoneBook, communication
        var id: String { rawValue }
    }

    private var settings: AppSettings { appSettings?.settings ?? AppSettings() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let items = OpenItem.items(for: store.state, now: context.date, reminders: settings.reminders)
            let dashboard = SituationDashboard(state: store.state)
            ScrollView {
                VStack(spacing: Spacing.l) {
                    keyFigures(dashboard, items: items, now: context.date)
                    toolBar
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Spacing.xl) {
                            VStack(spacing: Spacing.xl) {
                                openItemsCard(items, now: context.date)
                                DemandCard(store: store)
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
                            openItemsCard(items, now: context.date)
                            triageCard(dashboard)
                            DemandCard(store: store)
                            statusCard
                            unitCard(dashboard)
                            hospitalCard(dashboard)
                            journalCard
                        }
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(item: $sheet) { tool in
            Group {
                switch tool {
                case .report: SituationReportSheet(store: store)
                case .checklist: ChecklistSheet(store: store, template: settings.checklist(for: store.state.mission.type))
                case .handover: HandoverSheet(store: store, people: people, template: settings.checklist(for: store.state.mission.type))
                case .hospitals: HospitalQuotaSheet(store: store, hospitals: masterData?.hospitals ?? [])
                case .leadership: LeadershipSheet(store: store)
                case .phoneBook: PhoneBookSheet(store: store, settings: settings, hospitals: masterData?.hospitals ?? [])
                case .communication: CommunicationPlanSheet(store: store)
                }
            }
            .largeSheet()
        }
    }

    /// Lagemeldung, Checkliste, Führung, Kliniken, Übergabe – je ein großer Knopf.
    private var toolBar: some View {
        let template = settings.checklist(for: store.state.mission.type)
        let checked = store.state.checkedItems
        let done = template.items.filter { checked[$0.id] != nil }.count
        let last = store.state.lastSituationReportAt
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.m) {
                toolButton("Lagemeldung", detail: last.map { "zuletzt \($0.formatted(date: .omitted, time: .shortened))" } ?? "noch keine", symbol: "antenna.radiowaves.left.and.right", tool: .report, prominent: true)
                toolButton("Checkliste", detail: "\(done) von \(template.items.count)", symbol: "checklist", tool: .checklist)
                toolButton("Führung", detail: leadershipDetail, symbol: "person.3.sequence", tool: .leadership)
                toolButton("Kliniken", detail: hospitalDetail, symbol: "cross.case", tool: .hospitals)
                toolButton("Übergabe", detail: "an die Ablösung", symbol: "arrow.left.arrow.right", tool: .handover)
                toolButton("Telefonbuch", detail: "ILS, Kliniken, Führung", symbol: "phone", tool: .phoneBook)
                toolButton("Kommunikation", detail: communicationDetail, symbol: "antenna.radiowaves.left.and.right.circle", tool: .communication)
            }
        }
    }

    private var leadershipDetail: String {
        let count = store.state.mission.leadership?.count ?? 0
        let strength = ForceOverview(state: store.state).strengthText
        return strength ?? (count == 0 ? "nicht erfasst" : "\(count) Funktionen")
    }

    private var communicationDetail: String {
        let channels = CommunicationPlan(store.state).channels.count
        return channels == 0 ? "Kanäle, Rufnamen" : (channels == 1 ? "1 Kanal" : "\(channels) Kanäle")
    }

    private var hospitalDetail: String {
        let loads = HospitalDistribution.loads(store.state)
        if loads.contains(where: { !$0.overloadedTriages.isEmpty }) { return "über Kontingent!" }
        return loads.isEmpty ? "Kontingente" : "\(loads.count) Kliniken"
    }

    private func toolButton(_ title: String, detail: String, symbol: String, tool: Tool, prominent: Bool = false) -> some View {
        Button { sheet = tool } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).opacity(0.8).lineLimit(1)
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: TouchTarget.large)
            .background(prominent ? AnyShapeStyle(ActionFill.primary) : AnyShapeStyle(Surface.card), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
    }

    /// Ziele, die die Lage selbst öffnet.
    private func handle(_ target: OpenItem.Target) {
        switch target {
        case .situationReport: sheet = .report
        case .hospitals: sheet = .hospitals
        default: onTarget(target)
        }
    }

    // MARK: Offene Punkte

    private func openItemsCard(_ items: [OpenItem], now: Date) -> some View {
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
                // Schritt 129: gleichartige Punkte zusammengefasst, der dringendste hervorgehoben.
                let entries = OpenItem.grouped(items)
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Divider()
                    switch entry {
                    case .single(let item):
                        OpenItemRow(item: item, onAcknowledge: store.state.mission.isClosed ? nil : { acknowledge(item) }) { handle(item.target) }
                            .background(index == 0 ? Self.highlight(item.triage) : Color.clear)
                    case .group(let group):
                        groupRow(group, highlighted: index == 0)
                    }
                }
            }
            // Schritt 96: abgehakte Punkte wieder anzeigen.
            let acknowledged = OpenItem.acknowledgedItems(for: store.state, now: now, reminders: settings.reminders)
            if !acknowledged.isEmpty {
                Divider()
                Button {
                    do { try store.perform(RestoreOpenItems()) } catch { journalError = ErrorText.message(for: error) }
                } label: {
                    Label(acknowledged.count == 1 ? "1 abgehakter Punkt – wieder anzeigen" : "\(acknowledged.count) abgehakte Punkte – wieder anzeigen",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum, alignment: .leading)
                        .padding(.horizontal, Spacing.xl)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    /// Dringendster Punkt: zart in der SK-Farbe hinterlegt.
    static func highlight(_ triage: Sichtungskategorie?) -> Color {
        (triage.map { Color.triage($0) } ?? Color.accentColor).opacity(0.12)
    }

    @ViewBuilder
    private func groupRow(_ group: OpenItemGroup, highlighted: Bool) -> some View {
        let expanded = expandedGroups.contains(group.id)
        let numbers = group.items.compactMap { item -> String? in
            guard case .patient(let id) = item.target else { return nil }
            return store.state.patients.first { $0.id == id }.map { "\($0.number)" }
        }
        let summary = OpenItem(id: group.id, kind: group.kind, triage: group.triage, title: group.title,
                               detail: numbers.isEmpty ? group.items.first?.detail ?? "" : group.detail(numbers: numbers),
                               actionTitle: group.actionTitle, target: group.target)
        VStack(spacing: 0) {
            OpenItemRow(item: summary, count: group.count, onAcknowledge: store.state.mission.isClosed ? nil : {
                group.items.forEach(acknowledge)
            }) { handle(group.target) }
            Button {
                withAnimation(.snappy) {
                    if expanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                }
            } label: {
                Label(expanded ? "Einzeln ausblenden" : "Einzeln zeigen (\(group.count))",
                      systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum, alignment: .leading)
                    .padding(.leading, Spacing.xl + 64 + Spacing.l)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            if expanded {
                ForEach(group.items) { item in
                    Divider().padding(.leading, Spacing.xl)
                    OpenItemRow(item: item, onAcknowledge: store.state.mission.isClosed ? nil : { acknowledge(item) }) { handle(item.target) }
                        .padding(.leading, Spacing.xl)
                }
            }
        }
        .background(highlighted ? Self.highlight(group.triage) : Color.clear)
    }

    // MARK: Kennzahlen (Schritt 129)

    /// Eine Zeile mit dem Wichtigsten: Laufzeit, Patienten, wartend, freie Transportmittel,
    /// nächste Lagemeldung.
    private func keyFigures(_ dashboard: SituationDashboard, items: [OpenItem], now: Date) -> some View {
        let state = store.state
        let waiting = state.patients.active.filter { $0.outcome == nil && !$0.hasTransportUnit(in: state.units) }.count
        let interval = settings.reminders.situationReportMinutes
        let last = state.lastSituationReportAt ?? state.mission.startedAt
        let due = interval > 0 ? interval - max(0, Int(now.timeIntervalSince(last) / 60)) : nil
        let figures: [(String, String, Color?)] = [
            (ElapsedTimeFormat.string(from: state.mission.startedAt, to: now), "Laufzeit", nil),
            ("\(dashboard.patientTotal)", "Patienten", nil),
            ("\(waiting)", "ohne Transport", waiting > 0 ? .orange : nil),
            ("\(dashboard.freeTransport)", "Transportmittel frei", dashboard.freeTransport == 0 && waiting > 0 ? .orange : nil),
            (due.map { $0 <= 0 ? "jetzt" : "\($0) min" } ?? "–", "nächste Lagemeldung", (due ?? 1) <= 0 ? .orange : nil),
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) {
                ForEach(figures, id: \.1) { figure in keyFigure(figure.0, figure.1, figure.2) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.s)], spacing: Spacing.s) {
                ForEach(figures, id: \.1) { figure in keyFigure(figure.0, figure.1, figure.2) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func keyFigure(_ value: String, _ label: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.heavy).monospacedDigit())
                .foregroundStyle(color ?? Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func acknowledge(_ item: OpenItem) {
        do {
            try store.perform(AcknowledgeOpenItem(itemID: item.id, description: item.protocolDescription(in: store.state)))
        } catch {
            journalError = ErrorText.message(for: error)
        }
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
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
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
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
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
            .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(label)")
    }

    // MARK: Kliniken

    /// Verteilung auf Kliniken mit Kontingent (Schritt 71); Tipp öffnet die Kontingente.
    @ViewBuilder
    private func hospitalCard(_ dashboard: SituationDashboard) -> some View {
        let loads = HospitalDistribution.loads(store.state)
        if !loads.isEmpty {
            Button { sheet = .hospitals } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Verteilung auf Kliniken").font(.title2.weight(.bold)).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(Spacing.xl)
                    ForEach(loads) { load in
                        Divider()
                        HStack(spacing: Spacing.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(load.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                if !load.overloadedTriages.isEmpty {
                                    Label("über Kontingent", systemImage: "exclamationmark.triangle.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: Spacing.m)
                            ForEach([Sichtungskategorie.sk1, .sk2, .sk3], id: \.self) { triage in
                                let count = load.counts[triage] ?? 0
                                let limit = load.quota?.limit(for: triage)
                                if count > 0 || limit != nil {
                                    Text(limit.map { "\(count)/\($0)" } ?? "\(count)")
                                        .font(.headline.weight(.heavy).monospacedDigit())
                                        .foregroundStyle(Color.onTriage(triage))
                                        .frame(minWidth: 48, minHeight: 32)
                                        .padding(.horizontal, Spacing.xs)
                                        .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                                .strokeBorder(Color.orange, lineWidth: load.isOverloaded(triage) ? 3 : 0)
                                        }
                                        .accessibilityLabel(limit.map { "\(triage.displayName): \(count) von \($0)" } ?? "\(count) \(triage.displayName)")
                                }
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
                .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            }
            .buttonStyle(.plain)
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
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
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
            .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                Button(action: addJournalEntry) {
                    Image(systemName: "arrow.up")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: TouchTarget.comfortable, height: TouchTarget.comfortable)
                        .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
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
    /// Schritt 129: Anzahl bei Gruppen (kleine Zahl am Kennzeichen).
    var count: Int? = nil
    /// „Zur Kenntnis genommen“ (Schritt 96); `nil` = kein Abhaken.
    var onAcknowledge: (() -> Void)? = nil
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
            acknowledgeButton
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
                HStack(spacing: Spacing.s) {
                    actionButton
                    acknowledgeButton
                }
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

    @ViewBuilder private var acknowledgeButton: some View {
        if let onAcknowledge {
            Button(action: onAcknowledge) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Zur Kenntnis genommen")
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
        markerBase
            .overlay(alignment: .topTrailing) {
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.primary.opacity(0.85), in: Circle())
                        .offset(x: 8, y: -8)
                        .accessibilityLabel("\(count) Punkte")
                }
            }
    }

    @ViewBuilder private var markerBase: some View {
        if let triage = item.triage {
            Text(triage.shortName)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.onTriage(triage))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .accessibilityLabel(triage.displayName)
        } else {
            Image(systemName: item.kind == .unreadMessages ? "bell" : "box.truck")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// Schritt 128: Checkliste und Lagemeldung als Formularblatt, alles andere in Seitengröße.
private struct ToolSheetSizing: ViewModifier {
    let tool: SituationOverview.Tool

    func body(content: Content) -> some View {
        switch tool {
        case .checklist, .report: content.formSheet()
        default: content.largeSheet()
        }
    }
}
