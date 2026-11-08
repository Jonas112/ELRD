import SwiftUI
import UIKit
import CloudKit
import ELRDDomain
import ELRDStore
import ELRDCloud

/// Verbindung zwischen System (Push, angenommene Einladungen) und App.
///
/// Push-Mitteilungen und Einladungen können eintreffen, bevor die App ihre
/// Umgebung aufgebaut hat oder jemand angemeldet ist. Sie werden hier
/// gesammelt und abgearbeitet, sobald der Koordinator bereitsteht.
@MainActor
@Observable
public final class CloudInbox {
    public static let shared = CloudInbox()

    /// Vom System übergebene Einladungen, die noch angenommen werden müssen.
    public private(set) var pendingShares: [CKShare.Metadata] = []
    @ObservationIgnored weak var coordinator: CloudSyncCoordinator?
    @ObservationIgnored private var missedPush = false

    private init() {}

    func attach(_ coordinator: CloudSyncCoordinator) {
        self.coordinator = coordinator
        if missedPush {
            missedPush = false
            coordinator.syncAll()
        }
    }

    func receive(_ metadata: CKShare.Metadata) {
        pendingShares.append(metadata)
    }

    func takeShares() -> [CKShare.Metadata] {
        defer { pendingShares.removeAll() }
        return pendingShares
    }

    /// Stille Push-Mitteilung: abgleichen (im Hintergrund höchstens ~25 s).
    func remoteChange() async {
        guard let coordinator else {
            missedPush = true
            return
        }
        await coordinator.syncAllNow(timeout: 25)
    }
}

/// App-Delegate für Push-Mitteilungen und Einladungslinks (iCloud-Teilen).
public final class ELRDAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Beispieldaten (Bildschirmfotos, Oberflächentests): kein iCloud.
        if AppLaunchOptions.current.demoScreen == nil {
            application.registerForRemoteNotifications()
        }
        return true
    }

    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ELRDSceneDelegate.self
        return configuration
    }

    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await CloudInbox.shared.remoteChange()
        return .newData
    }
}

/// Nimmt Einladungslinks entgegen (aus Nachrichten, Mail oder Kamera geöffnet).
public final class ELRDSceneDelegate: NSObject, UIWindowSceneDelegate {
    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            MainActor.assumeIsolated { CloudInbox.shared.receive(metadata) }
        }
    }

    public func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        MainActor.assumeIsolated { CloudInbox.shared.receive(cloudKitShareMetadata) }
    }
}
