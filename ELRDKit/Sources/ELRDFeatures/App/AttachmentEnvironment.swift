import SwiftUI
import ELRDPersistence

private struct AttachmentStoreKey: EnvironmentKey {
    /// Vorschauen und Tests: eigener temporärer Ordner.
    static let defaultValue: AttachmentFileStore = .temporary()
}

extension EnvironmentValues {
    /// Dateiablage für Anhänge (in `RootView` aus der `AppEnvironment` gesetzt).
    var attachmentStore: AttachmentFileStore {
        get { self[AttachmentStoreKey.self] }
        set { self[AttachmentStoreKey.self] = newValue }
    }
}
