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

/// Nach der Anmeldung. Bis Schritt 16 (Einsatzliste) mit dem Beispieleinsatz.
struct SignedInView: View {
    let environment: AppEnvironment
    let user: UserAccount

    @State private var demoStore: MissionStore? = nil

    var body: some View {
        Group {
            if let demoStore {
                MissionWorkspaceView(store: demoStore, account: account)
            } else {
                ProgressView()
            }
        }
        .task(id: user.id) {
            demoStore = try? PreviewData.makeStore()
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
