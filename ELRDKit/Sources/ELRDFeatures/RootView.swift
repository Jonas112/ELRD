import SwiftUI
import ELRDAuth
import ELRDStore

/// Einstiegsansicht der App: Start → Ersteinrichtung / Anmeldung → Arbeitsbereich.
public struct RootView: View {
    let options: AppLaunchOptions

    @State private var environment: AppEnvironment?
    @State private var startupError: String?

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
            } else if let startupError {
                ContentUnavailableView(
                    "ELRD konnte nicht starten",
                    systemImage: "exclamationmark.triangle",
                    description: Text(startupError)
                )
            } else {
                ProgressView("ELRD wird gestartet …")
            }
        }
        .task {
            guard environment == nil else { return }
            do {
                environment = try await AppEnvironment.make(options: options)
            } catch {
                startupError = error.localizedDescription
            }
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
                    initialPatientLayout: environment.demoScreen.map { $0 == .patientTiles ? .tiles : .list } ?? .stored
                ) {
                    self.openStore = nil
                    list?.reload()
                }
            } else if let list {
                MissionListView(
                    model: list,
                    account: account,
                    masterData: masterData,
                    isAdmin: user.role == .admin,
                    showsNewMissionInitially: environment.demoScreen == .newMission,
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
