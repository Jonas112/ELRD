import SwiftUI
import ELRDFeatures

@main
struct ELRDApp: App {
    /// Push-Mitteilungen und Einladungslinks für das iCloud-Teilen.
    @UIApplicationDelegateAdaptor(ELRDAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands {
            WorkspaceCommands()
        }
    }
}
