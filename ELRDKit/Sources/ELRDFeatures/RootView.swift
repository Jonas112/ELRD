import SwiftUI
import ELRDStore

/// Einstiegsansicht der App.
///
/// Bis Anmeldung und Einsatzliste stehen (Schritte 15–16), öffnet die App einen
/// Beispieleinsatz im Arbeitsspeicher. Es wird nichts gespeichert.
public struct RootView: View {
    @State private var store: MissionStore?

    public init() {
        _store = State(initialValue: try? PreviewData.makeStore())
    }

    public var body: some View {
        if let store {
            MissionWorkspaceView(store: store)
        } else {
            ContentUnavailableView(
                "Beispieleinsatz nicht verfügbar",
                systemImage: "exclamationmark.triangle",
                description: Text("Die Beispieldaten konnten nicht erzeugt werden.")
            )
        }
    }
}

#Preview {
    RootView()
}
