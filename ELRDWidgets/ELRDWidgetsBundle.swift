import SwiftUI
import WidgetKit
import ELRDLiveActivity

/// Widget-Erweiterung: nur die Live Activity des laufenden Einsatzes (Schritt 90).
@main
struct ELRDWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MissionLiveActivityWidget()
    }
}
