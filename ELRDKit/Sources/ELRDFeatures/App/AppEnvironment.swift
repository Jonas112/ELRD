import Foundation
import UIKit
import Observation
import ELRDDomain
import ELRDPersistence
import ELRDAuth
import ELRDEntitlements
import ELRDStammdaten
import ELRDStore
import ELRDCloud
import CloudKit

/// Startoptionen, u. a. für automatische Bildschirmfotos in der CI.
///
/// `--demo-screen setup|login|missions|newMission|workspace|missionDetails|patients|patientDetail|injuries` startet mit
/// Beispieldaten im Arbeitsspeicher (nichts wird gespeichert, Keychain bleibt unberührt).
public struct AppLaunchOptions: Equatable, Sendable {
    public enum DemoScreen: String, Sendable, CaseIterable {
        case setup, login, missions, newMission, workspace, missionDetails, patients, patientTiles, patientDetail, injuries, unitPicker, sections, addUnit, addPlaceholder, replacePlaceholder, map, mapCollapsed, mapTopo, mapObject, mapDrawing, journal, journalEntry, protocolLog, messages, report, settings, masterData, onboarding
        /// Schritte 67–76.
        case situationReport, checklist, leadership, hospitals, transportBoard, handover, journalNew, missionTimeline, triageGuide, newExercise, whereabouts, statistics, debrief, distribution, communicationPlan, mapSigns, mapPath, patientDetailPerson, patientDetailCondition, patientDetailTransport, mapExport, communicationChart, search

        /// Bildschirme, die einen angemeldeten Benutzer mit Beispieleinsätzen brauchen.
        var needsMissions: Bool { ![.setup, .login].contains(self) }

        /// Bildschirme, die direkt im laufenden Beispieleinsatz starten.
        var opensRunningMission: Bool { ![.setup, .login, .missions, .newMission, .newExercise, .statistics, .settings, .masterData, .onboarding].contains(self) }

        /// Bereich, in dem der Arbeitsbereich startet.
        var initialWorkspaceSection: WorkspaceSection {
            if [.patients, .patientTiles, .transportBoard, .whereabouts].contains(self) || opensPatient { return .patients }
            if [.map, .mapCollapsed, .mapTopo, .mapObject, .mapDrawing, .mapSigns, .mapPath, .mapExport].contains(self) { return .map }
            if [.journal, .journalEntry, .journalNew, .protocolLog, .missionTimeline, .debrief].contains(self) { return .journal }
            return [.sections, .addUnit, .addPlaceholder, .replacePlaceholder].contains(self) ? .organisation : .overview
        }

        /// Bildschirme, die direkt einen Patienten öffnen.
        var opensPatient: Bool { [.patientDetail, .injuries, .unitPicker, .triageGuide, .patientDetailPerson, .patientDetailCondition, .patientDetailTransport].contains(self) }
    }

    public let demoScreen: DemoScreen?

    public init(demoScreen: DemoScreen? = nil) {
        self.demoScreen = demoScreen
    }

    public init(arguments: [String]) {
        if let index = arguments.firstIndex(of: "--demo-screen"), arguments.indices.contains(index + 1) {
            demoScreen = DemoScreen(rawValue: arguments[index + 1])
        } else {
            demoScreen = nil
        }
    }

    public static var current: AppLaunchOptions { AppLaunchOptions(arguments: ProcessInfo.processInfo.arguments) }
}

/// Alles, was die App zur Laufzeit braucht – einmal beim Start aufgebaut.
@MainActor
@Observable
public final class AppEnvironment {
    public let repository: any EntityRepository & DocumentRepository
    public let userService: UserService
    public let device: DeviceIdentity
    public let deviceClock: DeviceClock
    public let entitlements: any EntitlementProvider
    /// Abo über StoreKit (Schritt 51); `nil` bei Beispieldaten.
    public let subscriptions: StoreKitEntitlements?
    /// Dateien zu Anhängen (Zeichnungen, Kartenausschnitte, Fotos).
    public let attachments: AttachmentFileStore
    /// Geräteeinstellungen (Schritt 47) und Berichtsvorlagen (Schritt 45).
    public let settings: AppSettingsStore
    public let reportLibrary: ReportLibraryStore
    /// Ungesendete Texte (Schritt 52).
    public let drafts: TextDraftStore
    /// Abgleich über iCloud (bei Beispieldaten ein Ersatz im Arbeitsspeicher).
    public let cloud: CloudSyncCoordinator?
    /// CloudKit-Zugang (Einladungen annehmen, die das System übergibt).
    let cloudStore: CloudKitZoneStore?
    /// Hinweise und Mitteilungen bei neuen offenen Punkten (Schritt 83).
    let notifier: OpenItemNotifier
    /// Live Activity des geöffneten Einsatzes (Schritt 90).
    let liveActivity: LiveActivityController
    /// `true` bei Beispieldaten im Arbeitsspeicher.
    public let isDemo: Bool
    /// Gewünschter Beispielbildschirm (nur Demo).
    public let demoScreen: AppLaunchOptions.DemoScreen?

    init(
        repository: any EntityRepository & DocumentRepository,
        userService: UserService,
        device: DeviceIdentity,
        entitlements: any EntitlementProvider,
        attachments: AttachmentFileStore,
        isDemo: Bool,
        demoScreen: AppLaunchOptions.DemoScreen? = nil
    ) throws {
        self.repository = repository
        self.attachments = attachments
        self.settings = AppSettingsStore(repository: repository)
        self.reportLibrary = ReportLibraryStore(repository: repository)
        self.drafts = TextDraftStore(repository: repository)
        self.userService = userService
        self.device = device
        self.deviceClock = try DeviceClock(deviceID: device.deviceID, repository: repository)
        self.entitlements = entitlements
        self.subscriptions = entitlements as? StoreKitEntitlements
        self.isDemo = isDemo
        self.demoScreen = demoScreen
        notifier = OpenItemNotifier(enabled: !isDemo)
        liveActivity = LiveActivityController(enabled: !isDemo)
        if isDemo {
            // Beispieldaten: iCloud-Ersatz im Arbeitsspeicher, CloudKit bleibt unberührt.
            cloudStore = nil
            cloud = CloudSyncCoordinator(
                repository: repository,
                clock: deviceClock,
                deviceID: device.deviceID,
                files: attachments,
                store: InMemoryCloudZoneStore()
            )
        } else {
            let store = CloudKitZoneStore()
            cloudStore = store
            cloud = CloudSyncCoordinator(
                repository: repository,
                clock: deviceClock,
                deviceID: device.deviceID,
                files: attachments,
                store: store
            )
        }
        cloud?.onImported = { [weak self] missions in self?.reloadOpenStores(missions) }
    }

    // MARK: iCloud-Abgleich

    /// Geöffnete Einsätze (schwach gehalten), damit übernommene Änderungen sofort sichtbar werden.
    @ObservationIgnored private var openStores: [WeakMissionStore] = []
    /// Wird nach übernommenen Änderungen aufgerufen (Einsatzliste neu laden).
    @ObservationIgnored var onMissionsChanged: (() -> Void)?
    @ObservationIgnored private var accountObserver: Task<Void, Never>?

    /// Einsatz geöffnet: eigene Änderungen an iCloud melden, regelmäßig nachsehen.
    func register(_ store: MissionStore) {
        openStores.removeAll { $0.store == nil || $0.store === store }
        openStores.append(WeakMissionStore(store: store))
        guard let cloud else { return }
        store.didCommit = { [weak cloud] mission in cloud?.noteLocalChange(mission) }
        cloud.startPolling(store.missionID)
    }

    func unregister(_ store: MissionStore) {
        openStores.removeAll { $0.store == nil || $0.store === store }
        cloud?.stopPolling()
    }

    private func reloadOpenStores(_ missions: Set<MissionID>) {
        // Auch im Hintergrund (Push): neue offene Punkte als Mitteilung melden.
        let isActive = UIApplication.shared.applicationState == .active
        for entry in openStores {
            guard let store = entry.store, missions.contains(store.missionID) else { continue }
            try? store.reload()
            notifier.evaluate(store.state, now: Date(), settings: settings.settings, appIsActive: isActive)
        }
        onMissionsChanged?()
    }

    /// Beim Start: nur wenn schon Einsätze verbunden sind, iCloud ansprechen.
    func startCloud() async {
        guard let cloud, !isDemo else { return }
        CloudInbox.shared.attach(cloud)
        if accountObserver == nil {
            accountObserver = Task { [weak cloud] in
                for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                    guard let cloud, cloud.hasLinks else { continue }
                    await cloud.accountDidChange()
                }
            }
        }
        if cloud.hasLinks { await cloud.activate() }
    }

    /// Vom System übergebene Einladungen annehmen; liefert den zuletzt beigetretenen Einsatz.
    func acceptPendingShares() async throws -> MissionID? {
        guard let cloud, let cloudStore else { return nil }
        var joined: MissionID?
        for metadata in CloudInbox.shared.takeShares() {
            let zone = try await cloudStore.accept(metadata)
            joined = try await cloud.joinAccepted(zone, url: metadata.share.url)
        }
        if joined != nil { onMissionsChanged?() }
        return joined
    }

    /// Startet passend zu den Startoptionen.
    public static func make(options: AppLaunchOptions) async throws -> AppEnvironment {
        if let screen = options.demoScreen { return try await demo(screen: screen) }
        return try live()
    }

    /// Echte App: SwiftData auf dem Gerät, Keychain.
    /// Abo über StoreKit; in Debug-Builds (Xcode) ist alles frei (E76).
    static func liveEntitlements() -> StoreKitEntitlements {
        #if DEBUG
        let forceDevelopment = true
        #else
        let forceDevelopment = false
        #endif
        let entitlements = StoreKitEntitlements(trial: StoreKitEntitlements.storedTrial(), forceDevelopment: forceDevelopment)
        Task { await entitlements.refresh() }
        return entitlements
    }

    public static func live() throws -> AppEnvironment {
        let repository = SwiftDataRepository(container: try PersistenceStore.makeContainer())
        let device = try loadOrCreateDevice(in: repository)
        try seedMasterDataIfNeeded(in: repository)
        let users = try UserService(repository: repository, secureStore: KeychainStore())
        try users.restoreSession()
        return try AppEnvironment(
            repository: repository,
            userService: users,
            device: device,
            entitlements: Self.liveEntitlements(),
            attachments: try AttachmentFileStore.standard(),
            isDemo: false
        )
    }

    /// Beispielumgebung im Arbeitsspeicher.
    public static func demo(screen: AppLaunchOptions.DemoScreen) async throws -> AppEnvironment {
        let repository = InMemoryRepository()
        let device = try loadOrCreateDevice(in: repository)
        try seedMasterDataIfNeeded(in: repository)
        let users = try UserService(
            repository: repository,
            secureStore: InMemorySecureStore(),
            provider: LocalAuthProvider(hasher: PasswordHasher(iterations: 1_000))
        )
        if screen != .setup {
            let admin = try await users.createInitialAdmin(firstName: "Erika", lastName: "Beispiel", callsign: "ELRD 1", password: "demo123")
            try await users.createUser(
                NewUser(firstName: "Max", lastName: "Muster", callsign: "ELRD 2", role: .commander, password: nil)
            )
            try await users.createUser(
                NewUser(firstName: "Jana", lastName: "Probe", callsign: "OrgL 1", role: .commander, password: "probe12")
            )
            try users.logout()
            if screen.needsMissions { try await users.login(admin.id, password: "demo123") }
        }
        let environment = try AppEnvironment(
            repository: repository,
            userService: users,
            device: device,
            entitlements: StaticEntitlements.development(),
            attachments: .temporary(),
            isDemo: true,
            demoScreen: screen
        )
        if screen.needsMissions {
            // Region Schweinfurt (Fahrzeuge, Kliniken Unterfranken) für Klinikauswahl und Entfernungen.
            if let region = BundledMasterData.region(id: "schweinfurt"),
               var master = try repository.document(MasterDataSet.self, key: .masterData) {
                _ = master.merge(try BundledMasterData.package(for: region).package)
                try repository.saveDocument(master, key: .masterData, at: Date())
            }
        }
        if screen.needsMissions, let user = users.currentUser {
            try DemoMissions.seed(in: environment, user: user)
            // Banner für die Einsatzliste (Schritt 78) – nur Beispieldaten.
            try environment.settings.update { settings in
                settings.organisationName = "BRK Kreisverband Musterstadt"
                settings.bannerImage = DemoMissions.demoBannerPNG()
            }
        }
        // Bildschirmfoto „Einsatzdaten“: laufender Einsatz ist geteilt.
        if screen == .missionDetails, let cloud = environment.cloud,
           let running = try MissionOverview.load(from: repository).first(where: { $0.endedAt == nil }) {
            _ = try await cloud.startSharing(running.id, title: running.title)
            await cloud.syncNow(running.id)
        }
        return environment
    }

    /// Gerätekennung und Nummernpräfix; beim ersten Start mit „A“ angelegt.
    static func loadOrCreateDevice(in repository: any DocumentRepository) throws -> DeviceIdentity {
        if let stored = try repository.document(DeviceIdentity.self, key: .device) { return stored }
        // Präfix „A“ ist immer gültig.
        let identity = DeviceIdentity(deviceID: DeviceID(), numberPrefix: DeviceIdentity.defaultPrefix)!
        try repository.saveDocument(identity, key: .device, at: Date())
        return identity
    }

    /// Diagnosekatalog und IVENA-Auswahl beim ersten Start.
    static func seedMasterDataIfNeeded(in repository: any DocumentRepository) throws {
        guard try repository.document(MasterDataSet.self, key: .masterData) == nil else { return }
        try repository.saveDocument(BundledMasterData.initialMasterData(), key: .masterData, at: Date())
    }
}

public extension DocumentKey {
    /// Identität dieses Geräts (`DeviceIdentity`).
    static let device = DocumentKey(rawValue: "device")
}

/// Schwacher Verweis auf einen geöffneten Einsatz.
private struct WeakMissionStore {
    weak var store: MissionStore?
}
