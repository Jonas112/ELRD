import SwiftUI
import ELRDDomain
import ELRDStore

/// Arbeitsbereich eines Einsatzes.
///
/// Immer gleich aufgebaut (E55–E57): oben die Lageleiste (Einsatz, Laufzeit,
/// SK-Zähler, „+ Patient“), links eine schmale Symbolleiste mit fünf Bereichen.
/// Bei wenig Breite (iPad mini hoch, schmale Fenster) wandert die Leiste nach unten.
public struct MissionWorkspaceView: View {
    let store: MissionStore
    let account: AccountMenuModel?
    let people: [PersonChoice]
    let catalogs: PatientCatalogs
    let masterData: MasterDataEditor?
    let journalTemplates: JournalTemplateEditor?
    let onClose: (() -> Void)?

    @State private var selection: WorkspaceSection
    @State private var showsMessages = AppLaunchOptions.current.demoScreen == .messages
    @State private var showsReport = AppLaunchOptions.current.demoScreen == .report
    @State private var showsDetails: Bool
    @State private var showsQuickAdd = false
    @State private var lastAdded: Patient?
    @State private var errorMessage: String?
    @State private var patientQuery = PatientListQuery()
    /// Geöffnete Patienten im Bereich (Navigation per Wert).
    @State private var path: [PatientID] = []
    /// ⌘J: Tagebuch öffnen und Eingabe fokussieren.
    @State private var focusJournal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        store: MissionStore,
        account: AccountMenuModel? = nil,
        people: [PersonChoice] = [],
        catalogs: PatientCatalogs = .empty,
        masterData: MasterDataEditor? = nil,
        journalTemplates: JournalTemplateEditor? = nil,
        showsDetailsInitially: Bool = false,
        initialSection: WorkspaceSection = .overview,
        initialPatient: PatientID? = nil,
        initialPatientLayout: PatientListLayout = .stored,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self.account = account
        self.people = people
        self.catalogs = catalogs
        self.masterData = masterData
        self.journalTemplates = journalTemplates
        self.onClose = onClose
        _showsDetails = State(initialValue: showsDetailsInitially)
        _selection = State(initialValue: initialSection)
        _path = State(initialValue: initialPatient.map { [$0] } ?? [])
        _patientQuery = State(initialValue: PatientListQuery(layout: initialPatientLayout))
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = WorkspaceLayout.forWidth(proxy.size.width)
            let badges = WorkspaceBadges(state: store.state)
            Group {
                switch layout {
                case .rail:
                    HStack(spacing: 0) {
                        WorkspaceRail(
                            selection: $selection,
                            badges: badges,
                            account: account,
                            onMessages: { showsMessages = true },
                            onReport: { showsReport = true }
                        )
                        VStack(spacing: 0) {
                            situationBar(layout: layout, badges: badges)
                            closedBanner
                            content
                        }
                    }
                case .bottomBar:
                    VStack(spacing: 0) {
                        situationBar(layout: layout, badges: badges)
                        closedBanner
                        content
                        WorkspaceTabBar(selection: $selection, badges: badges)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let lastAdded {
                    UndoToast(
                        text: "\(lastAdded.number) · \(lastAdded.triage.shortName) angelegt",
                        color: Color.triage(lastAdded.triage),
                        undo: { undo(lastAdded) },
                        show: { open(lastAdded.id); self.lastAdded = nil }
                    )
                    .padding(.bottom, layout == .bottomBar ? 104 : Spacing.xxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: lastAdded?.id)
        }
        .background(Surface.canvas)
        .focusedSceneValue(\.workspaceSelection, $selection)
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            newJournalEntry: {
                path = []
                selection = .journal
                focusJournal = true
            },
            openMessages: { showsMessages = true },
            openReport: { showsReport = true },
            openDetails: { showsDetails = true }
        ))
        .task(id: lastAdded?.id) {
            guard lastAdded != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { lastAdded = nil }
        }
        .sheet(isPresented: $showsMessages) { MessagesView(store: store).largeSheet() }
        .fullScreenCover(isPresented: $showsReport) {
            ReportEditorView(store: store, people: people) { showsReport = false }
        }
        .sheet(isPresented: $showsDetails) { MissionDetailsView(store: store, people: people).largeSheet() }
        .alert("Aktion nicht möglich", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func situationBar(layout: WorkspaceLayout, badges: WorkspaceBadges) -> some View {
        SituationBar(
            mission: store.state.mission,
            counts: Patient.countsByTriage(store.state.patients),
            layout: layout,
            unreadMessages: badges.unreadMessages,
            account: account,
            canAddPatients: !store.state.mission.isClosed && store.isEnabled(.missionEditing),
            showsQuickAdd: $showsQuickAdd,
            // Solange ein Patient offen ist, zeigt nur dessen Leiste „Zurück“ – zwei
            // Zurück-Knöpfe übereinander führten zum versehentlichen Verlassen des Einsatzes.
            onClose: path.isEmpty ? onClose : nil,
            onDetails: { showsDetails = true },
            onMessages: { showsMessages = true },
            onReport: { showsReport = true },
            onTriage: { category in
                // Tipp auf einen Zähler: Patienten dieser Kategorie zeigen.
                patientQuery = PatientListQuery(triage: category, sort: patientQuery.sort, layout: patientQuery.layout)
                selection = .patients
                path.removeAll()
            },
            onQuickAdd: addPatient
        )
    }

    /// Hinweis bei beendetem Einsatz: nur Ansicht, mit „Wieder öffnen“.
    @ViewBuilder private var closedBanner: some View {
        let mission = store.state.mission
        if mission.isClosed {
            HStack(spacing: Spacing.m) {
                Image(systemName: "flag.checkered").font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Einsatz beendet – nur Ansicht").font(.headline)
                    if let endedAt = mission.endedAt {
                        Text("Ende \(endedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Spacing.m)
                Button("Wieder öffnen", action: reopen)
                    .font(.headline)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!store.isEnabled(.missionEditing))
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.m)
            .background(Surface.elevated)
        }
    }

    private func reopen() {
        do {
            try store.perform(ReopenMission())
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private var content: some View {
        NavigationStack(path: $path) {
            WorkspaceDetail(section: selection, store: store, masterData: masterData, journalTemplates: journalTemplates, people: people, patientQuery: $patientQuery, focusJournal: $focusJournal, onQuickAdd: addPatient) { target in
                switch target {
                case .section(let section): selection = section
                case .patient(let id): open(id)
                case .messages: showsMessages = true
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PatientID.self) { id in
                PatientDetailView(
                    store: store,
                    patientID: id,
                    order: patientQuery.apply(to: store.state.patients).map(\.id),
                    onNavigate: { next in
                        if !path.isEmpty { path[path.count - 1] = next }
                    },
                    catalogs: catalogs
                )
                // Neuer Zustand je Patient (Formular, Speicherstand).
                .id(id)
            }
            // Der Stack bringt sonst seinen eigenen (im hellen Modus weißen) Hintergrund mit.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Surface.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bereichswechsel über die Leiste: zurück zur Übersicht des Bereichs.
        .onChange(of: selection) { path.removeAll() }
    }

    /// Öffnet einen Patienten (z. B. aus „Offene Punkte“ oder der Schnellanlage).
    private func open(_ id: PatientID) {
        if selection != .patients {
            selection = .patients
            // Nach dem Bereichswechsel öffnen (der Wechsel leert den Pfad).
            Task { @MainActor in path = [id] }
        } else {
            path = [id]
        }
    }

    private func addPatient(_ triage: Sichtungskategorie) {
        showsQuickAdd = false
        do {
            let added = try store.perform(AddPatient(triage: triage))
            lastAdded = added
            // VoiceOver: der Hinweis unten verschwindet nach 6 s, daher ansagen.
            let announcement: String = "Patient \(added.number), \(added.triage.displayName) angelegt"
            AccessibilityNotification.Announcement(announcement).post()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func undo(_ patient: Patient) {
        lastAdded = nil
        do {
            try store.perform(DeletePatient(patientID: patient.id))
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Lageleiste

/// Feste Leiste oben: Einsatz, Laufzeit, SK-Zähler und „+ Patient“.
struct SituationBar: View {
    let mission: Mission
    let counts: [Sichtungskategorie: Int]
    let layout: WorkspaceLayout
    let unreadMessages: Int
    let account: AccountMenuModel?
    let canAddPatients: Bool
    @Binding var showsQuickAdd: Bool
    let onClose: (() -> Void)?
    let onDetails: () -> Void
    let onMessages: () -> Void
    let onReport: () -> Void
    let onTriage: (Sichtungskategorie) -> Void
    let onQuickAdd: (Sichtungskategorie) -> Void

    static let counterOrder: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet]

    var body: some View {
        Group {
            switch layout {
            case .rail:
                HStack(spacing: Spacing.l) {
                    backButton
                    missionTitle
                    Spacer(minLength: Spacing.m)
                    HStack(spacing: Spacing.s) { counters(compact: false) }
                    addButton
                }
                .padding(.horizontal, Spacing.xl)
                .frame(minHeight: 96)
            case .bottomBar:
                VStack(spacing: Spacing.m) {
                    HStack(spacing: Spacing.m) {
                        backButton
                        missionTitle
                        Spacer(minLength: Spacing.s)
                        ReportButton(action: onReport)
                        MessagesBellButton(unread: unreadMessages, action: onMessages)
                        if let account { AccountAvatarMenu(account: account) }
                    }
                    HStack(spacing: Spacing.s) {
                        counters(compact: true)
                        addButton
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
            }
        }
        .background(Surface.card)
    }

    @ViewBuilder private var backButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .frame(width: TouchTarget.comfortable, height: TouchTarget.comfortable)
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zurück zur Einsatzliste")
        }
    }

    /// Titel und Laufzeit; ein Tipp öffnet die Einsatzdaten.
    private var missionTitle: some View {
        Button(action: onDetails) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(mission.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(subtitle(now: context.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: TouchTarget.comfortable, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Öffnet die Einsatzdaten")
    }

    private func subtitle(now: Date) -> String {
        let state = mission.isClosed
            ? "beendet"
            : "läuft \(ElapsedTimeFormat.string(from: mission.startedAt, to: now))"
        // Laufzeit zuerst: wird es eng, kürzt sich der Ort, nicht die Zeit.
        let parts = layout == .rail
            ? [state, mission.displayNumber(), mission.location]
            : [state, mission.displayNumber()]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func counters(compact: Bool) -> some View {
        ForEach(Self.counterOrder, id: \.self) { category in
            TriageCounterButton(category: category, count: counts[category] ?? 0, fillsWidth: compact) {
                onTriage(category)
            }
        }
    }

    private var addButton: some View {
        Button { showsQuickAdd = true } label: {
            Label("Patient", systemImage: "plus")
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: layout == .rail ? 64 : TouchTarget.comfortable)
                .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canAddPatients)
        .opacity(canAddPatients ? 1 : 0.4)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .accessibilityLabel("Neuer Patient")
        .popover(isPresented: $showsQuickAdd, arrowEdge: .top) {
            QuickAddPanel(onAdd: onQuickAdd)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// SK-Zähler, ein Tipp führt zu den Patienten.
struct TriageCounterButton: View {
    let category: Sichtungskategorie
    let count: Int
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(category.shortName)
                    .font(.caption.weight(.bold))
                Text("\(count)")
                    .font(.system(size: 28, weight: .heavy))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.onTriage(category))
            .frame(minWidth: 72, maxWidth: fillsWidth ? .infinity : 88, minHeight: fillsWidth ? TouchTarget.comfortable : 64)
            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.displayName): \(count)")
        .accessibilityHint("Zeigt die Patienten")
    }
}

/// Schnellanlage: ein Tipp legt den Patienten mit der nächsten Nummer an.
struct QuickAddPanel: View {
    let onAdd: (Sichtungskategorie) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Neuer Patient").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(SituationBar.counterOrder, id: \.self) { category in
                    Button { onAdd(category) } label: {
                        Text("+ \(category == .ungesichtet ? "ungesichtet" : category.shortName)")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.onTriage(category))
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Patient \(category.displayName) anlegen")
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 400)
    }
}

/// Hinweis nach der Schnellanlage mit „Rückgängig“ und „Details“.
struct UndoToast: View {
    let text: String
    let color: Color
    let undo: () -> Void
    let show: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(color).frame(width: 14, height: 14)
            Text(text).font(.headline)
            Button("Rückgängig", action: undo)
                .font(.headline)
                .frame(minHeight: TouchTarget.comfortable)
                .padding(.horizontal, Spacing.s)
            Button(action: show) {
                Text("Öffnen")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: TouchTarget.minimum + 4)
                    .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Bereichsleisten

/// Schmale Symbolleiste links: fünf Bereiche, unten Nachrichten und Konto.
struct WorkspaceRail: View {
    @Binding var selection: WorkspaceSection
    let badges: WorkspaceBadges
    let account: AccountMenuModel?
    let onMessages: () -> Void
    let onReport: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            ForEach(WorkspaceSection.allCases) { section in
                SectionButton(section: section, isSelected: selection == section, badge: badges.badge(for: section), height: 76) {
                    selection = section
                }
                .frame(width: 80)
            }
            Spacer(minLength: Spacing.l)
            ReportButton(action: onReport)
            MessagesBellButton(unread: badges.unreadMessages, action: onMessages)
            if let account { AccountAvatarMenu(account: account) }
        }
        .padding(.vertical, Spacing.l)
        .frame(width: 96)
        .frame(maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .trailing) { Rectangle().fill(Surface.separator).frame(width: 0.5) }
    }
}

/// Leiste unten (iPad mini hoch, schmale Fenster).
struct WorkspaceTabBar: View {
    @Binding var selection: WorkspaceSection
    let badges: WorkspaceBadges

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(WorkspaceSection.allCases) { section in
                SectionButton(section: section, isSelected: selection == section, badge: badges.badge(for: section), height: 64) {
                    selection = section
                }
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.s)
        .background(Color(uiColor: .secondarySystemBackground), ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Rectangle().fill(Surface.separator).frame(height: 0.5) }
    }
}

/// Bereichsknopf mit Symbol, Beschriftung und Zähler.
struct SectionButton: View {
    let section: WorkspaceSection
    let isSelected: Bool
    let badge: Int
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(height: 26)
                Text(section.title)
                    .font(.caption.weight(isSelected ? .bold : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(isSelected ? ActionFill.selected : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Surface.elevated, in: Capsule())
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(section.title), \(badge) offen" : section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Glocke für Nachrichten mit Zähler.
/// Bericht erstellen (Schritt 44).
struct ReportButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: TouchTarget.comfortable, height: TouchTarget.comfortable)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(0.8))
        .accessibilityLabel("Bericht erstellen")
    }
}

struct MessagesBellButton: View {
    let unread: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: unread > 0 ? "bell.badge" : "bell")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: TouchTarget.comfortable, height: TouchTarget.comfortable)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color.orange, in: Circle())
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(0.8))
        .accessibilityLabel(unread > 0 ? "Nachrichten, \(unread) ungelesen" : "Nachrichten")
    }
}

/// Nachrichten (Schritt 36).
// MARK: - Inhalt

/// Inhalt des gewählten Bereichs. Die übrigen Bereiche entstehen in den folgenden Schritten.
struct WorkspaceDetail: View {
    let section: WorkspaceSection
    let store: MissionStore
    let masterData: MasterDataEditor?
    let journalTemplates: JournalTemplateEditor?
    let people: [PersonChoice]
    @Binding var patientQuery: PatientListQuery
    @Binding var focusJournal: Bool
    let onQuickAdd: (Sichtungskategorie) -> Void
    let onTarget: (OpenItem.Target) -> Void

    var body: some View {
        switch section {
        case .overview:
            SituationOverview(store: store, onTarget: onTarget)
        case .patients:
            PatientsView(store: store, query: $patientQuery, onQuickAdd: onQuickAdd)
        case .organisation:
            SectionsView(store: store, templates: masterData) { onTarget(.patient($0)) }
        case .map:
            MissionMapView(store: store)
        case .journal:
            JournalView(store: store, templates: journalTemplates, people: people, focusComposer: $focusJournal)
        }
    }
}

#Preview("Arbeitsbereich") {
    if let store = try? PreviewData.makeStore() {
        MissionWorkspaceView(store: store, account: AccountMenuModel(displayName: "Erika Beispiel", detail: "ELRD 1", signOut: {}), onClose: {})
    }
}
