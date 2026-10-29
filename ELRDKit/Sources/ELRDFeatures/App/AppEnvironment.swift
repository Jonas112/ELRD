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
/// `--demo-screen setup|login|workspace` startet mit Beispieldaten im
/// Arbeitsspeicher (nichts wird gespeichert, Keychain bleibt unberührt).
public struct AppLaunchOptions: Equatable, Sendable {
    public enum DemoScreen: String, Sendable, CaseIterable {
        case setup, login, workspace
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
    public let entitlements: StaticEntitlements
    /// `true` bei Beispieldaten im Arbeitsspeicher.
    public let isDemo: Bool

    init(
        repository: any EntityRepository & DocumentRepository,
        userService: UserService,
        device: DeviceIdentity,
        entitlements: StaticEntitlements,
        isDemo: Bool
    ) throws {
        self.repository = repository
        self.userService = userService
        self.device = device
        self.deviceClock = try DeviceClock(deviceID: device.deviceID, repository: repository)
        self.entitlements = entitlements
        self.isDemo = isDemo
    }

    /// Startet passend zu den Startoptionen.
    public static func make(options: AppLaunchOptions) async throws -> AppEnvironment {
        if let screen = options.demoScreen { return try await demo(screen: screen) }
        return try live()
    }

    /// Echte App: SwiftData auf dem Gerät, Keychain.
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
            entitlements: StaticEntitlements.development(),
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
            try await users.createInitialAdmin(firstName: "Erika", lastName: "Beispiel", callsign: "ELRD 1", password: "demo123")
            let commander = try await users.createUser(
                NewUser(firstName: "Max", lastName: "Muster", callsign: "ELRD 2", role: .commander, password: nil)
            )
            try await users.createUser(
                NewUser(firstName: "Jana", lastName: "Probe", callsign: "OrgL 1", role: .commander, password: "probe12")
            )
            try users.logout()
            if screen == .workspace { try await users.login(commander.id, password: nil) }
        }
        return try AppEnvironment(
            repository: repository,
            userService: users,
            device: device,
            entitlements: StaticEntitlements.development(),
            isDemo: true
        )
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
