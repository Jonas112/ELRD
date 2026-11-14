import SwiftUI
import ELRDDomain
import ELRDStore
import ELRDPersistence
import ELRDCloud

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
    /// Schritt 134: globale Suche (⌘K).
    @State private var showsSearch = AppLaunchOptions.current.demoScreen == .search
    /// Breite des Inhalts (Schritt 130, geteilte Ansicht ab 1050 pt).
    @State private var contentWidth: CGFloat = 0
    /// Lernpfad (Schritt 139): was die App nicht aus den Daten sieht.
    @State private var tutorialProgress = TutorialProgress()
    /// Schritt 133: „Rückgängig“ nach schnellen Aktionen (ersetzt den Hinweis nur für neue Patienten).
    @State private var undoCenter = UndoCenter()
    @State private var errorMessage: String?
    @State private var patientQuery = PatientListQuery()
    /// Geöffnete Patienten im Bereich (Navigation per Wert).
    @State private var path: [PatientID] = []
    /// ⌘J: Tagebuch öffnen und Eingabe fokussieren.
    @State private var focusJournal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(OpenItemNotifier.self) private var notifier: OpenItemNotifier?
    @Environment(LiveActivityController.self) private var liveActivity: LiveActivityController?
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @Environment(CloudSyncCoordinator.self) private var cloud: CloudSyncCoordinator?
    /// Schritt 143: neuer Stand aus Alamos FE2 für übernommene Einsätze.
    @Environment(AlamosInbox.self) private var alamos: AlamosInbox?
    /// Schritt 143: Vorschau eines neuen FE2-Stands.
    @State private var reviewedAlarm: AlamosAlarm?
    @Environment(\.attachmentStore) private var attachments
    /// Schritt 109: Lagebild wird gerade erstellt (MapKit braucht einen Moment).
    @State private var snapshotInProgress = false

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
            let badges = WorkspaceBadges(state: store.state, notifications: notifier?.unreadCount(for: store.missionID) ?? 0)
            Group {
                switch layout {
                case .rail:
                    HStack(spacing: 0) {
                        WorkspaceRail(
                            selection: $selection,
                            badges: badges,
                            account: account,
                            onMessages: { showsMessages = true },
                            onReport: { showsReport = true },
                            onSearch: { showsSearch = true },
                            onClose: onClose
                        )
                        VStack(spacing: 0) {
                            situationBar(layout: layout, badges: badges)
                            exerciseBanner
                            closedBanner
                            alamosBanner
                            content
                        }
                    }
                case .bottomBar:
                    VStack(spacing: 0) {
                        situationBar(layout: layout, badges: badges)
                        exerciseBanner
                        closedBanner
                        alamosBanner
                        content
                        WorkspaceTabBar(selection: $selection, badges: badges)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let item = undoCenter.current {
                    UndoToast(
                        text: item.text,
                        color: item.color,
                        undo: { undoCenter.performUndo() },
                        show: item.open == nil ? nil : { undoCenter.performOpen() }
                    )
                    .id(item.id)
                    .padding(.bottom, layout == .bottomBar ? 104 : Spacing.xxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if store.state.mission.isTutorial == true || AppLaunchOptions.current.demoScreen == .tutorial, !store.state.mission.isClosed {
                    TutorialCoach(state: store.state, progress: tutorialProgress) { section in
                        path.removeAll()
                        selection = section
                    }
                    .padding(.leading, layout == .bottomBar ? Spacing.m : 96 + Spacing.l)
                    .padding(.trailing, Spacing.m)
                    .padding(.bottom, layout == .bottomBar ? 96 : Spacing.l)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: undoCenter.current?.id)
            .environment(\.undoCenter, undoCenter)
            // Schritt 83: neuer offener Punkt als Hinweis oben.
            .overlay(alignment: .top) {
                if let item = notifier?.banner {
                    OpenItemBanner(
                        item: item,
                        onOpen: {
                            notifier?.dismissBanner()
                            path = []
                            handle(item.target)
                        },
                        onDismiss: { notifier?.dismissBanner() }
                    )
                    .padding(.top, Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
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
        // Schritt 116: Beitrittsanfragen an eigene Freigaben (alle 15 s, nur wenn geteilt).
        .overlay(alignment: .top) {
            if let cloud { JoinRequestBanner(cloud: cloud, mission: store.missionID) }
        }
        .task(id: cloud?.link(for: store.missionID)?.requiresApproval == true) {
            guard let cloud, cloud.link(for: store.missionID)?.requiresApproval == true else { return }
            while !Task.isCancelled {
                await cloud.checkJoinRequests()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        // Schritt 120: bei Einsatzende GPX-Freigaben für Hundeteams löschen.
        .onChange(of: store.state.mission.isClosed) { _, closed in
            guard closed, appSettings?.settings.deletesGPXSharesOnClose ?? true else { return }
            let mission = store.missionID
            Task { await GPXShareCenter.shared.removeAll(for: mission) }
        }
        // Offene Punkte im Minutentakt prüfen (Erinnerungen werden mit der Zeit fällig).
        .task {
            // Schritt 89: im geteilten Einsatz als Teilnehmer eintragen.
            if cloud?.link(for: store.missionID) != nil, !store.state.mission.isClosed {
                _ = try? store.perform(JoinAsParticipant())
            }
            notifier?.requestAuthorizationIfNeeded()
            while !Task.isCancelled {
                evaluateOpenItems()
                releaseDueInjects()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: store.state) {
            let settings = appSettings?.settings ?? AppSettings()
            notifier?.acknowledge(store.state, now: Date(), settings: settings)
            liveActivity?.update(store.state, settings: settings, now: Date())
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { evaluateOpenItems() }
        }
        .onDisappear {
            notifier?.forget(store.state.mission.id)
            liveActivity?.end()
        }
        // Schritt 84: angetippte Mitteilung dieses Einsatzes → zum Punkt.
        .onChange(of: NotificationInbox.shared.pending, initial: true) {
            guard let route = NotificationInbox.shared.take(for: store.missionID) else { return }
            notifier?.dismissBanner()
            if let target = route.target {
                path = []
                handle(target)
            }
        }
        .task(id: undoCenter.current?.id) {
            guard let id = undoCenter.current?.id else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { undoCenter.dismiss(id) }
        }
        .alert("Rückgängig nicht möglich", isPresented: Binding(get: { undoCenter.errorMessage != nil }, set: { if !$0 { undoCenter.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoCenter.errorMessage ?? "")
        }
        .sheet(isPresented: $showsSearch) {
            GlobalSearchSheet(store: store, canAddPatients: !store.state.mission.isClosed && store.isEnabled(.missionEditing)) { kind in
                handleSearch(kind)
            }
            .formSheet()
        }
        .background {
            // ⌘K öffnet die Suche (Hardware-Tastatur).
            Button("Suchen") { showsSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showsMessages) {
            MessagesView(store: store) { target in
                showsMessages = false
                path = []
                handle(target)
            }
            .formSheet()
        }
        .onChange(of: showsReport) { _, shows in if shows { tutorialProgress.openedReport = true } }
        .fullScreenCover(isPresented: $showsReport) {
            ReportEditorView(store: store, people: people, hospitals: catalogs.hospitals) { showsReport = false }
        }
        .sheet(isPresented: $showsDetails) { MissionDetailsView(store: store, people: people).largeSheet() }
        .sheet(item: $reviewedAlarm) { alamosReview($0) }
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
            onSearch: { showsSearch = true },
            onTriage: { category in
                // Tipp auf einen Zähler: Patienten dieser Kategorie zeigen.
                patientQuery = PatientListQuery(triage: category, sort: patientQuery.sort, layout: patientQuery.layout)
                selection = .patients
                path.removeAll()
            },
            onQuickAdd: addPatient
        )
    }

    /// Übung (Schritt 88): schmales violettes Band, damit niemand sie mit einem
    /// echten Einsatz verwechselt.
    @ViewBuilder private var exerciseBanner: some View {
        if store.state.mission.isExerciseMission {
            Label("ÜBUNG", systemImage: "graduationcap.fill")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(Color.purple)
                .accessibilityLabel("Übungseinsatz")
        }
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

    /// Schritt 143: Hinweis auf einen neuen FE2-Stand (nur laufende, übernommene Einsätze).
    @ViewBuilder private var alamosBanner: some View {
        if let alarm = linkedAlarm, let update = AlarmUpdate(alarm: alarm, state: store.state, masterUnits: masterData?.units ?? []) {
            AlamosUpdateBanner(
                update: update,
                canEdit: store.isEnabled(.missionEditing),
                onApply: { selection in
                    if let message = applyAlarmChanges(alarm, selection) { errorMessage = message }
                },
                onDiscard: { selection in
                    if let message = discardAlarmChanges(alarm, selection) { errorMessage = message }
                },
                onReview: { reviewedAlarm = alarm },
                onDismiss: {
                    do {
                        try store.perform(DismissAlarmUpdate(revision: alarm.revision))
                        alamos?.markSeen(alarm)
                    } catch {
                        errorMessage = ErrorText.message(for: error)
                    }
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .task {
                if AppLaunchOptions.current.demoScreen == .alamosUpdateReview { reviewedAlarm = alarm }
            }
        }
    }

    /// Neuester Stand des FE2-Einsatzes, aus dem dieser Einsatz übernommen wurde.
    private var linkedAlarm: AlamosAlarm? {
        guard let alamos, let reference = store.state.mission.externalAlarm, !store.state.mission.isClosed else { return nil }
        return alamos.alarms.first { $0.externalId == reference.externalID }
    }

    /// Schritt 145: Ereignisse übernehmen; Fehlertext oder `nil`.
    private func applyAlarmChanges(_ alarm: AlamosAlarm, _ selection: AlarmUpdateSelection) -> String? {
        do {
            try store.perform(ApplyAlarmUpdate(alarm: alarm, selection: selection, masterUnits: masterData?.units ?? []))
            alamos?.markSeen(alarm)
            return nil
        } catch {
            return ErrorText.message(for: error)
        }
    }

    /// Schritt 145: Ereignisse verwerfen (erledigt, nichts angelegt); Fehlertext oder `nil`.
    private func discardAlarmChanges(_ alarm: AlamosAlarm, _ selection: AlarmUpdateSelection) -> String? {
        do {
            try store.perform(DiscardAlarmChanges(alarm: alarm, selection: selection))
            alamos?.markSeen(alarm)
            return nil
        } catch {
            return ErrorText.message(for: error)
        }
    }

    /// Alle Ereignisse einzeln; zeigt immer den neuesten Stand.
    @ViewBuilder private func alamosReview(_ selected: AlamosAlarm) -> some View {
        let alarm = linkedAlarm ?? selected
        if let update = AlarmUpdate(alarm: alarm, state: store.state, masterUnits: masterData?.units ?? []) {
            AlamosUpdateSheet(
                update: update,
                canEdit: store.isEnabled(.missionEditing),
                onApply: { applyAlarmChanges(alarm, $0) },
                onDiscard: { discardAlarmChanges(alarm, $0) }
            )
            .largeSheet()
        } else {
            NavigationStack {
                ContentUnavailableView("Nichts mehr offen", systemImage: "checkmark.circle", description: Text("Alle Änderungen aus Alamos FE2 sind übernommen, verworfen oder ausgeblendet."))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { reviewedAlarm = nil }
                        }
                    }
            }
            .formSheet()
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
        // Schritt 130: Auf dem breiten iPad Patientenliste und Patient nebeneinander.
        // Breite nur im Hintergrund messen – ein GeometryReader um den Navigationsstapel
        // ließ die Patientenliste beim Start hängen.
        Group {
            if selection == .patients, contentWidth >= Self.splitMinimumWidth, let current = path.last {
                splitView(current)
            } else {
                stack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in contentWidth = width }
            }
        }
        // Bereichswechsel über die Leiste: zurück zur Übersicht des Bereichs.
        .onChange(of: selection) { path.removeAll() }
    }

    /// Ab dieser Breite (iPad quer) stehen Liste und Patient nebeneinander.
    static let splitMinimumWidth: CGFloat = 1050

    private var stack: some View {
        NavigationStack(path: $path) {
            WorkspaceDetail(section: selection, store: store, masterData: masterData, journalTemplates: journalTemplates, people: people, patientQuery: $patientQuery, focusJournal: $focusJournal, onQuickAdd: addPatient) { target in
                handle(target)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PatientID.self) { id in
                patientDetail(id, onClose: nil)
            }
            // Der Stack bringt sonst seinen eigenen (im hellen Modus weißen) Hintergrund mit.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Surface.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func splitView(_ current: PatientID) -> some View {
        HStack(spacing: 0) {
            PatientsView(store: store, query: $patientQuery, onQuickAdd: addPatient, selectedID: current) { open($0) }
                // Schmale Spalte: Darstellung wie auf dem iPhone (Liste statt Tabelle).
                .environment(\.horizontalSizeClass, .compact)
                .frame(width: 400)
                .background(Surface.canvas)
            Divider()
            NavigationStack {
                patientDetail(current, onClose: { path.removeAll() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Surface.canvas)
            }
        }
    }

    private func patientDetail(_ id: PatientID, onClose: (() -> Void)?) -> some View {
        PatientDetailView(
            store: store,
            patientID: id,
            order: patientQuery.apply(to: store.state.patients).map(\.id),
            onNavigate: { next in
                if !path.isEmpty { path[path.count - 1] = next }
            },
            catalogs: catalogs,
            onClose: onClose
        )
        // Neuer Zustand je Patient (Formular, Speicherstand).
        .id(id)
    }

    /// Führt zu einem offenen Punkt (aus der Lage oder dem Hinweis oben).
    private func handle(_ target: OpenItem.Target) {
        switch target {
        case .section(let section): selection = section
        case .patient(let id): open(id)
        case .messages: showsMessages = true
        // Lagemeldung und Kliniken öffnet die Lage selbst.
        case .situationReport, .hospitals: selection = .overview
        }
    }

    private func evaluateOpenItems() {
        liveActivity?.update(store.state, settings: appSettings?.settings ?? AppSettings(), now: Date())
        notifier?.evaluate(
            store.state,
            now: Date(),
            settings: appSettings?.settings ?? AppSettings(),
            appIsActive: scenePhase == .active
        )
        takeSituationSnapshotIfDue()
    }

    /// Schritt 109: automatisches Lagebild im eingestellten Takt.
    private func takeSituationSnapshotIfDue() {
        let settings = appSettings?.settings ?? AppSettings()
        let interval = settings.reminders.situationSnapshotMinutes
        let now = Date()
        guard !snapshotInProgress,
              AppLaunchOptions.current.demoScreen == nil,
              SituationSnapshot.isResponsible(store.state.mission, userID: store.sessionUserID),
              SituationSnapshot.isDue(store.state, intervalMinutes: interval, now: now) else { return }
        snapshotInProgress = true
        Task { @MainActor in
            defer { snapshotInProgress = false }
            // Halber Takt als Sperre: kam inzwischen ein Lagebild von einem anderen
            // Gerät, entsteht kein zweites.
            _ = try? await SituationSnapshotRenderer.capture(
                store: store, settings: settings, attachments: attachments, minimumGap: TimeInterval(interval * 30)
            )
        }
    }

    /// Schritt 138: geplante Übungseinlagen einspielen – nur das Gerät der
    /// Einsatzleitung (bzw. ohne Teilnehmer jedes), damit nichts doppelt kommt.
    private func releaseDueInjects() {
        let mission = store.state.mission
        guard mission.isExerciseMission, !mission.isClosed, mission.exerciseInjects?.contains(where: { !$0.isReleased }) == true else { return }
        let isLead = (mission.participants ?? []).isEmpty || mission.commanderID == store.sessionUserID
        guard isLead else { return }
        _ = try? store.perform(ReleaseDueExerciseInjects(now: Date()))
    }

    /// Treffer der globalen Suche öffnen (Schritt 134).
    private func handleSearch(_ kind: GlobalSearchResult.Kind) {
        switch kind {
        case .patient(let id): open(id)
        case .unit, .section: selection = .organisation
        case .area(let area): selection = area
        case .messages: showsMessages = true
        case .report: showsReport = true
        case .newPatient(let triage): addPatient(triage)
        }
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
            Haptics.success()
            undoCenter.offer("\(added.number) · \(added.triage.shortName) angelegt", color: Color.triage(added.triage),
                             open: { open(added.id) }) { [store] in
                _ = try store.perform(DeletePatient(patientID: added.id))
            }
            // VoiceOver: der Hinweis unten verschwindet nach 6 s, daher ansagen.
            let announcement: String = "Patient \(added.number), \(added.triage.displayName) angelegt"
            AccessibilityNotification.Announcement(announcement).post()
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
    let onSearch: () -> Void
    let onTriage: (Sichtungskategorie) -> Void
    let onQuickAdd: (Sichtungskategorie) -> Void

    static let counterOrder: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet]

    var body: some View {
        Group {
            switch layout {
            case .rail:
                // Breit: „Einsatz verlassen“ sitzt unten in der Seitenleiste (Jonas).
                HStack(spacing: Spacing.l) {
                    missionTitle
                    Spacer(minLength: Spacing.m)
                    HStack(spacing: Spacing.s) { counters(compact: false) }
                    addButton
                }
                .padding(.horizontal, Spacing.xl)
                .frame(minHeight: 96)
            case .bottomBar:
                VStack(spacing: Spacing.m) {
                    // iPhone: passt der Titel nicht, werden die Knöpfe auf 44 pt verkleinert,
                    // damit der Titel lesbar bleibt.
                    ViewThatFits(in: .horizontal) {
                        topRow(buttonSize: TouchTarget.comfortable, spacing: Spacing.m)
                        topRow(buttonSize: TouchTarget.minimum, spacing: Spacing.xs)
                    }
                    // iPhone: schmalere Zähler und „+“ ohne Text, damit alles in eine Zeile passt.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.s) {
                            counters(compact: true)
                            addButton
                        }
                        HStack(spacing: Spacing.xs) {
                            counters(compact: true, minWidth: 48)
                            addPatientButton(iconOnly: true)
                        }
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
            }
        }
        .background(Surface.card)
    }

    private func topRow(buttonSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            backButton(size: buttonSize)
            missionTitle
            Spacer(minLength: Spacing.xs)
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: buttonSize, height: buttonSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary.opacity(0.8))
            .accessibilityLabel("Suchen")
            ReportButton(size: buttonSize, action: onReport)
            MessagesBellButton(unread: unreadMessages, size: buttonSize, action: onMessages)
            if let account { AccountAvatarMenu(account: account, size: buttonSize) }
        }
    }

    @ViewBuilder private func backButton(size: CGFloat) -> some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .frame(width: size, height: size)
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zurück zur Einsatzliste")
        }
    }

    /// Titel und Laufzeit; ein Tipp öffnet die Einsatzdaten.
    /// Titel des Einsatzes als deutlich erkennbarer Knopf zu den Einsatzdaten
    /// (Jonas: der Pfeil allein wurde übersehen).
    private var missionTitle: some View {
        Button(action: onDetails) {
            HStack(spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(mission.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(subtitle(now: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    Label("Einsatzdaten", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.m)
                        .frame(minHeight: 36)
                        .background(ActionFill.primary, in: Capsule())
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(ActionFill.primary, in: Circle())
                }
                .layoutPriority(-1)
            }
            .padding(.leading, Spacing.m)
            .padding(.trailing, Spacing.s)
            .frame(minHeight: TouchTarget.comfortable, alignment: .leading)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(ActionFill.primary.opacity(0.35), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Öffnet die Einsatzdaten")
    }

    private func subtitle(now: Date) -> String {
        let state = mission.isClosed
            ? "beendet"
            : "läuft \(ElapsedTimeFormat.string(from: mission.startedAt, to: now))"
        // Laufzeit zuerst: wird es eng, kürzt sich der Ort, nicht die Zeit.
        let exercise = mission.isExerciseMission ? "ÜBUNG" : ""
        let parts = layout == .rail
            ? [exercise, state, mission.displayNumber(), mission.location]
            : [exercise, state, mission.displayNumber()]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func counters(compact: Bool, minWidth: CGFloat = 72) -> some View {
        ForEach(Self.counterOrder, id: \.self) { category in
            TriageCounterButton(category: category, count: counts[category] ?? 0, fillsWidth: compact, minWidth: minWidth) {
                onTriage(category)
            }
        }
    }

    private var addButton: some View { addPatientButton(iconOnly: false) }

    private func addPatientButton(iconOnly: Bool) -> some View {
        Button { showsQuickAdd = true } label: {
            Group {
                if iconOnly {
                    Image(systemName: "plus").frame(width: 28)
                } else {
                    Label("Patient", systemImage: "plus")
                }
            }
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, iconOnly ? Spacing.m : Spacing.l)
                .frame(minHeight: layout == .rail ? 64 : TouchTarget.comfortable)
                .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
    /// Mindestbreite (iPhone: schmaler).
    var minWidth: CGFloat = 72
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
            .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : 88, minHeight: fillsWidth ? TouchTarget.comfortable : 64)
            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
    /// `nil` = kein „Öffnen“.
    let show: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(color).frame(width: 14, height: 14)
            Text(text).font(.headline).lineLimit(2)
            Button("Rückgängig", action: undo)
                .font(.headline)
                .frame(minHeight: TouchTarget.comfortable)
                .padding(.horizontal, Spacing.s)
            if let show { Button(action: show) {
                Text("Öffnen")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: TouchTarget.minimum + 4)
                    .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
            .buttonStyle(.plain) }
        }
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
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
    var onSearch: () -> Void = {}
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.s) {
            ForEach(WorkspaceSection.allCases) { section in
                SectionButton(section: section, isSelected: selection == section, badge: badges.badge(for: section), height: 72) {
                    selection = section
                }
                .frame(width: 80)
            }
            Spacer(minLength: Spacing.l)
            Button(action: onSearch) {
                RailIcon(systemImage: "magnifyingglass", title: "Suchen", showsLabel: true, size: TouchTarget.comfortable)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary.opacity(0.8))
            .accessibilityLabel("Suchen")
            .accessibilityHint("Tastatur: Befehl K")
            ReportButton(showsLabel: true, action: onReport)
            MessagesBellButton(unread: badges.unreadMessages, showsLabel: true, action: onMessages)
            if let account { AccountAvatarMenu(account: account) }
            if let onClose {
                Divider().frame(width: 64).padding(.vertical, Spacing.xs)
                Button(action: onClose) {
                    VStack(spacing: 4) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 22, weight: .semibold))
                            .scaleEffect(x: -1, y: 1)
                        Text("Einsätze").font(.caption.weight(.semibold))
                    }
                    .frame(width: 80, height: 56)
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.85))
                .accessibilityLabel("Einsatz verlassen, zurück zur Einsatzliste")
            }
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
            .background(isSelected ? ActionFill.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
    var size: CGFloat = TouchTarget.comfortable
    /// Schritt 127: in der Seitenleiste mit Beschriftung.
    var showsLabel = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailIcon(systemImage: "doc.richtext", title: "Bericht", showsLabel: showsLabel, size: size)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(0.8))
        .accessibilityLabel("Bericht erstellen")
    }
}

struct MessagesBellButton: View {
    let unread: Int
    var size: CGFloat = TouchTarget.comfortable
    var showsLabel = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailIcon(systemImage: unread > 0 ? "bell.badge" : "bell", title: "Meldungen", showsLabel: showsLabel, size: size)
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
        .accessibilityLabel(unread > 0 ? "Benachrichtigungen, \(unread) ungelesen" : "Benachrichtigungen")
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
            SituationOverview(store: store, people: people, masterData: masterData, onTarget: onTarget)
        case .patients:
            PatientsView(store: store, query: $patientQuery, onQuickAdd: onQuickAdd) { onTarget(.patient($0)) }
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

/// Symbol der Seitenleiste, wahlweise mit Beschriftung darunter (Schritt 127).
struct RailIcon: View {
    let systemImage: String
    let title: String
    let showsLabel: Bool
    let size: CGFloat

    var body: some View {
        if showsLabel {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 22, weight: .semibold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(width: 80, height: 56)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}
