import SwiftUI
import ELRDFeatures

@main
struct ELRDApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands {
            WorkspaceCommands()
        }
    }
}
