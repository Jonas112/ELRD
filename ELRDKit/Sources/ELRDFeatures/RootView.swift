import SwiftUI
import ELRDAuth
import ELRDStore
import ELRDCloud

/// Einstiegsansicht der App: Start → Ersteinrichtung / Anmeldung → Arbeitsbereich.
public struct RootView: View {
    let options: AppLaunchOptions

    @State private var environment: AppEnvironment?
    @State private var startupError: String?
    @State private var startAttempt = 0
    @Environment(\.scenePhase) private var scenePhase

    public init(options: AppLaunchOptions = .current) {
        self.options = options
    }

    public var body: some View {
        Group {
            if let environment {
                AppFlowView(environment: environment)
                    .environment(\.attachmentStore, environment.attachments)
                    .environment(environment.settings)
                    .environment(environment.reportLibrary)
                    .environment(environment.subscriptions)
                    .environment(environment.drafts)
                    .environment(environment.cloud)
                    .environment(environment.notifier)
                    .environment(environment.liveActivity)
                    .modifier(DisplayModeModifier(settings: environment.settings))
            } else if let startupError {
                ContentUnavailableView {
                    Label("ELRD konnte nicht starten", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(startupError)
                } actions: {
                    Button("Erneut versuchen") {
                        self.startupError = nil
                        startAttempt += 1
                    }
                    .font(.headline)
                    .frame(minHeight: TouchTarget.comfortable)
                }
            } else {
                ProgressView("ELRD wird gestartet …")
            }
        }
        // Sehr große Schrift ja, aber nicht so groß, dass Leisten und Kacheln zerfallen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .task(id: startAttempt) {
            guard environment == nil else { return }
            do {
                let made = try await AppEnvironment.make(options: options)
                environment = made
                await made.startCloud()
            } catch {
                startupError = ErrorText.message(for: error)
            }
        }
        // Entwürfe sichern, bevor die App in den Hintergrund geht oder gesperrt wird.
        // Zurück im Vordergrund: verbundene Einsätze abgleichen (Push kann ausbleiben).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { environment?.drafts.flush() }
            if phase == .active, let cloud = environment?.cloud, cloud.hasLinks { cloud.syncAll() }
        }
    }
}

/// Wählt anhand des Anmeldestands die passende Ansicht.
struct AppFlowView: View {
    let environment: AppEnvironment

    var body: some View {
        let users = environment.userService
        if users.needsInitialSetup {
            InitialSetupView(userService: users)
        } else if let user = users.currentUser {
            SignedInView(environment: environment, user: user)
        } else {
            LoginView(userService: users)
        }
    }
}

/// Nach der Anmeldung: Einsatzliste, von dort in den Arbeitsbereich eines Einsatzes.
struct SignedInView: View {
    let environment: AppEnvironment
    let user: UserAccount

    @State private var list: MissionListModel?
    @State private var openStore: MissionStore?
    @State private var catalogs = PatientCatalogs.empty
    @State private var masterData: MasterDataEditor?
    @State private var journalTemplates: JournalTemplateEditor?
    @State private var showsOnboarding = false

    var body: some View {
        Group {
            if let openStore {
                MissionWorkspaceView(
                    store: openStore,
                    account: account,
                    people: people,
                    catalogs: catalogs,
                    masterData: masterData,
                    journalTemplates: journalTemplates,
                    showsDetailsInitially: environment.demoScreen == .missionDetails,
                    initialSection: environment.demoScreen?.initialWorkspaceSection ?? .overview,
                    initialPatient: environment.demoScreen?.opensPatient == true ? openStore.state.activePatients.first?.id : nil,
                    initialPatientLayout: environment.demoScreen.map { $0 == .patientTiles ? .tiles : $0 == .transportBoard ? .board : .list } ?? .stored
                ) {
                    environment.unregister(openStore)
                    self.openStore = nil
                    list?.reload()
                }
                .onAppear { environment.register(openStore) }
                .id(ObjectIdentifier(openStore))
            } else if let list {
                MissionListView(
                    model: list,
                    account: account,
                    masterData: masterData,
                    isAdmin: user.role == .admin,
                    showsNewMissionInitially: environment.demoScreen == .newMission || environment.demoScreen == .newExercise,
                    initialSettingsPage: environment.demoScreen == .settings ? .general : environment.demoScreen == .masterData ? .masterData : nil
                ) { store in
                    openStore = store
                }
            } else {
                ProgressView()
            }
        }
        // Einführung und Vereinbarungen (Schritt 50): beim ersten Mal und bei neuer Fassung.
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView(masterData: masterData) { showsOnboarding = false }
        }
        // Einladung über iCloud (Link aus Nachrichten/Kamera): annehmen und Einsatz öffnen.
        .task(id: CloudInbox.shared.pendingShares.count) {
            guard !CloudInbox.shared.pendingShares.isEmpty else { return }
            do {
                if let mission = try await environment.acceptPendingShares(), let list {
                    list.reload()
                    if openStore == nil { openStore = try? list.open(mission) }
                }
            } catch {
                list?.reportError(ErrorText.message(for: error))
            }
        }
        // Schritt 84: angetippte Mitteilung → Einsatz öffnen (Ziel übernimmt der Arbeitsbereich).
        .onChange(of: NotificationInbox.shared.pending) { openNotifiedMission() }
        .onChange(of: list == nil) { openNotifiedMission() }
        // Nach „Region laden“ stehen neue Kliniken gleich in der Klinikauswahl.
        .onChange(of: masterData?.revision) {
            catalogs = PatientCatalogs.load(from: environment.repository)
        }
        .task(id: user.id) {
            openStore = nil
            catalogs = PatientCatalogs.load(from: environment.repository)
            masterData = MasterDataEditor(repository: environment.repository)
            journalTemplates = JournalTemplateEditor(repository: environment.repository)
            let model = MissionListModel(environment: environment, user: user)
            list = model
            environment.onMissionsChanged = { [weak model] in model?.reload() }
            // Beispieldaten: Einführung nur auf dem eigenen Bildschirmfoto.
            let settings = environment.settings.settings
            showsOnboarding = environment.isDemo
                ? environment.demoScreen == .onboarding
                : !(settings.hasCompletedOnboarding && Agreements.isAccepted(settings))
            // Bildschirmfoto „Arbeitsbereich“: laufenden Beispieleinsatz direkt öffnen.
            if environment.demoScreen?.opensRunningMission == true, let running = model.result.running.first {
                openStore = try? model.open(running.id)
            }
        }
    }

    private func openNotifiedMission() {
        guard let route = NotificationInbox.shared.pending, let list,
              openStore?.missionID != route.missionID else { return }
        do {
            let store = try list.open(route.missionID)
            if let current = openStore { environment.unregister(current) }
            openStore = store
        } catch {
            // Einsatz gibt es hier nicht (mehr) – Mitteilung verwerfen.
            NotificationInbox.shared.discard()
        }
    }

    /// Aktive Benutzer zur Auswahl als Einsatzleiter.
    private var people: [PersonChoice] {
        environment.userService.directory.activeUsers.map {
            PersonChoice(id: $0.id, name: $0.displayName, detail: $0.callsign)
        }
    }

    private var account: AccountMenuModel {
        let detail = user.callsign.isEmpty ? user.role.displayName : user.callsign
        let service = environment.userService
        return AccountMenuModel(displayName: user.displayName, detail: detail) {
            try? service.logout()
        }
    }
}

/// Hilfsansicht für SwiftUI-Vorschauen mit Beispielumgebung.
struct PreviewEnvironmentView: View {
    let screen: AppLaunchOptions.DemoScreen

    var body: some View {
        RootView(options: AppLaunchOptions(demoScreen: screen))
    }
}

#Preview("Start (Anmeldung)") {
    PreviewEnvironmentView(screen: .login)
}

/// Handschuh- und Nachtmodus (Schritt 113) aus den Einstellungen anwenden.
/// Handschuhe: Schrift mindestens „sehr groß“, große Bedienelemente, Tippflächen
/// +30 %. Nacht: dunkle Darstellung und gedimmter Inhalt (Karte, Listen), damit
/// das Display bei Dunkelheit nicht blendet.
struct DisplayModeModifier: ViewModifier {
    let settings: AppSettingsStore
    private let mode = DisplayMode.shared

    func body(content: Content) -> some View {
        let glove = settings.settings.gloveMode
        let night = settings.settings.nightMode
        content
            .dynamicTypeSize(glove ? DynamicTypeSize.xxLarge...DynamicTypeSize.accessibility3 : DynamicTypeSize.xSmall...DynamicTypeSize.accessibility3)
            .controlSize(glove ? .large : .regular)
            .preferredColorScheme(night ? .dark : nil)
            .overlay {
                if night {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: settings.settings, initial: true) { _, new in
                mode.apply(new)
            }
    }
}
