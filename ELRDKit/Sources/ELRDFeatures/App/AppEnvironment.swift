import Foundation
import Observation
import ELRDDomain
import ELRDPersistence
import ELRDAuth
import ELRDEntitlements
import ELRDStammdaten
import ELRDStore

/// Startoptionen, u. a. für automatische Bildschirmfotos in der CI.
///
/// `--demo-screen setup|login|missions|newMission|workspace|missionDetails|patients|patientDetail|injuries` startet mit
/// Beispieldaten im Arbeitsspeicher (nichts wird gespeichert, Keychain bleibt unberührt).
public struct AppLaunchOptions: Equatable, Sendable {
    public enum DemoScreen: String, Sendable, CaseIterable {
        case setup, login, missions, newMission, workspace, missionDetails, patients, patientTiles, patientDetail, injuries, sections, addUnit, addPlaceholder, replacePlaceholder, map, mapTopo, mapObject, mapDrawing, journal, journalEntry, protocolLog, messages, report, settings, masterData, onboarding

        /// Bildschirme, die einen angemeldeten Benutzer mit Beispieleinsätzen brauchen.
        var needsMissions: Bool { ![.setup, .login].contains(self) }

        /// Bildschirme, die direkt im laufenden Beispieleinsatz starten.
        var opensRunningMission: Bool { ![.setup, .login, .missions, .newMission, .settings, .masterData, .onboarding].contains(self) }

        /// Bereich, in dem der Arbeitsbereich startet.
        var initialWorkspaceSection: WorkspaceSection {
            if [.patients, .patientTiles].contains(self) || opensPatient { return .patients }
            if [.map, .mapTopo, .mapObject, .mapDrawing].contains(self) { return .map }
            if [.journal, .journalEntry, .protocolLog].contains(self) { return .journal }
            return [.sections, .addUnit, .addPlaceholder, .replacePlaceholder].contains(self) ? .organisation : .overview
        }

        /// Bildschirme, die direkt einen Patienten öffnen.
        var opensPatient: Bool { [.patientDetail, .injuries].contains(self) }
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
