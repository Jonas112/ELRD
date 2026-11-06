import Foundation
import Testing
@testable import ELRDAuth
@testable import ELRDDomain
@testable import ELRDPersistence

@Suite("Passwort-Hash")
struct PasswordHasherTests {
    let hasher = PasswordHasher(iterations: 1_000)

    @Test func verifyAndReject() throws {
        let hash = try hasher.hash("Einsatz123")
        #expect(hash.algorithm == "pbkdf2-sha256")
        #expect(hash.salt.count == 16)
        #expect(hash.hash.count == 32)
        #expect(hasher.verify("Einsatz123", against: hash))
        #expect(!hasher.verify("einsatz123", against: hash))
        #expect(!hasher.verify("", against: hash))
    }

    @Test func saltMakesHashesUnique() throws {
        let first = try hasher.hash("gleich")
        let second = try hasher.hash("gleich")
        #expect(first.salt != second.salt)
        #expect(first.hash != second.hash)
    }

    @Test func unicodeNormalization() throws {
        let composed = "Rettungsübung"          // ü als ein Zeichen
        let decomposed = "Rettungsu\u{0308}bung" // u + kombinierendes Trema
        let hash = try hasher.hash(composed)
        #expect(hasher.verify(decomposed, against: hash))
    }

    @Test func rehashWhenIterationsIncrease() throws {
        let weak = try PasswordHasher(iterations: 500).hash("passwort")
        #expect(hasher.needsRehash(weak))
        #expect(!hasher.needsRehash(try hasher.hash("passwort")))
    }

    @Test func knownVectorPBKDF2SHA256() throws {
        // RFC 7914, Abschnitt 11: PBKDF2-HMAC-SHA256("passwd", "salt", 1) – erste 32 Byte.
        let stored = PasswordHash(
            algorithm: PasswordHash.pbkdf2SHA256,
            iterations: 1,
            salt: Data("salt".utf8),
            hash: Data(hex: "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
        )
        #expect(PasswordHasher(iterations: 1).verify("passwd", against: stored))
    }

    @Test func productionSettingStaysUsable() throws {
        let production = PasswordHasher()
        #expect(production.iterations == 600_000)
        let start = Date()
        let hash = try production.hash("Einsatz123")
        let seconds = Date().timeIntervalSince(start)
        #expect(production.verify("Einsatz123", against: hash))
        // Grobe Grenze, damit die Anmeldung im Einsatz nicht zäh wird. Großzügig, weil
        // die geteilten GitHub-Macs im Simulator schwanken (einmal 3,8 s); auf dem iPad schneller.
        #expect(seconds < 6, "Hashing dauerte \(seconds) s")
    }
}

@MainActor
final class AuthTestClock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)
}

@MainActor
struct AuthFixture {
    let repository = InMemoryRepository()
    let secureStore = InMemorySecureStore()
    let clock = AuthTestClock()

    func makeService() throws -> UserService {
        let clock = clock
        return try UserService(
            repository: repository,
            secureStore: secureStore,
            provider: LocalAuthProvider(hasher: PasswordHasher(iterations: 1_000)),
            now: { clock.now }
        )
    }
}

@Suite("Benutzer und Anmeldung")
@MainActor
struct UserServiceTests {
    @Test func initialSetupCreatesLoggedInAdmin() async throws {
        let fixture = AuthFixture()
        let service = try fixture.makeService()
        #expect(service.needsInitialSetup)

        let admin = try await service.createInitialAdmin(firstName: "Erika", lastName: "Beispiel", callsign: "ELRD 1", password: "geheim1")
        #expect(admin.isAdmin)
        #expect(admin.hasPassword)
        #expect(service.currentUser?.id == admin.id)
        #expect(!service.needsInitialSetup)
        #expect(admin.listTitle == "ELRD 1 - Erika Beispiel")

        await #expect(throws: AuthError.alreadyInitialized) {
            try await service.createInitialAdmin(firstName: "X", lastName: "Y", password: "geheim2")
        }
    }

    @Test func passwordIsNeverStoredInPlainText() async throws {
        let fixture = AuthFixture()
        let service = try fixture.makeService()
        try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "KlartextPasswort")
        let stored = try #require(try fixture.repository.document(UserDirectory.self, key: .users))
        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        #expect(!json.contains("KlartextPasswort"))
    }

    @Test func adminsNeedPasswordsAndPolicyApplies() async throws {
        let service = try AuthFixture().makeService()
        await #expect(throws: AuthError.passwordTooShort(minimum: 6)) {
            try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "123")
        }
        await #expect(throws: AuthError.passwordRequiredForAdmin) {
            try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "")
        }
        try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        let commander = try await service.createUser(NewUser(firstName: "Max", lastName: "Muster", role: .commander, password: nil))
        #expect(!commander.hasPassword)
        await #expect(throws: AuthError.passwordRequiredForAdmin) {
            try await service.createUser(NewUser(firstName: "C", lastName: "D", role: .admin, password: nil))
        }
        #expect(throws: AuthError.passwordRequiredForAdmin) { try service.setRole(.admin, for: commander.id) }
    }

    @Test func loginWithAndWithoutPassword() async throws {
        let service = try AuthFixture().makeService()
        let admin = try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        let commander = try await service.createUser(NewUser(firstName: "Max", lastName: "Muster", role: .commander, password: nil))
        try service.logout()

        try await service.login(commander.id, password: nil)
        #expect(service.currentUser?.id == commander.id)
        await #expect(throws: AuthError.invalidCredentials) { try await service.login(commander.id, password: "irgendwas") }

        await #expect(throws: AuthError.invalidCredentials) { try await service.login(admin.id, password: nil) }
        let loggedIn = try await service.login(admin.id, password: "geheim1")
        #expect(loggedIn.lastLoginAt != nil)
        await #expect(throws: AuthError.invalidCredentials) { try await service.login(UserID(), password: "geheim1") }
    }

    @Test func lockoutAfterFiveFailuresWithGrowingDuration() async throws {
        let fixture = AuthFixture()
        let service = try fixture.makeService()
        let admin = try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        try service.logout()

        for _ in 1...4 {
            await #expect(throws: AuthError.invalidCredentials) { try await service.login(admin.id, password: "falsch!") }
        }
        let firstLock = fixture.clock.now.addingTimeInterval(30)
        await #expect(throws: AuthError.lockedOut(until: firstLock)) { try await service.login(admin.id, password: "falsch!") }
        // Auch das richtige Passwort hilft während der Sperre nicht.
        await #expect(throws: AuthError.lockedOut(until: firstLock)) { try await service.login(admin.id, password: "geheim1") }

        fixture.clock.now = fixture.clock.now.addingTimeInterval(31)
        let secondLock = fixture.clock.now.addingTimeInterval(60)
        await #expect(throws: AuthError.lockedOut(until: secondLock)) { try await service.login(admin.id, password: "falsch!") }

        fixture.clock.now = fixture.clock.now.addingTimeInterval(61)
        try await service.login(admin.id, password: "geheim1")
        #expect(service.directory.user(admin.id)?.failedLoginCount == 0)
        #expect(service.directory.user(admin.id)?.lockedUntil == nil)
    }

    @Test func lastAdminIsProtected() async throws {
        let service = try AuthFixture().makeService()
        let admin = try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        #expect(throws: AuthError.lastAdmin) { try service.setRole(.commander, for: admin.id) }
        #expect(throws: AuthError.lastAdmin) { try service.deactivate(admin.id) }

        let second = try await service.createUser(NewUser(firstName: "C", lastName: "D", role: .admin, password: "geheim2"))
        try service.setRole(.commander, for: admin.id)
        #expect(service.directory.user(admin.id)?.role == .commander)
        #expect(service.currentUser?.isAdmin == false, "Angemeldeter Benutzer wird mit aktualisiert")
        #expect(throws: AuthError.notAuthorized) { try service.deactivate(second.id) }
    }

    @Test func commandersCannotManageOthers() async throws {
        let service = try AuthFixture().makeService()
        try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        let commander = try await service.createUser(NewUser(firstName: "Max", lastName: "Muster", role: .commander, password: "max123"))
        try service.logout()
        try await service.login(commander.id, password: "max123")

        await #expect(throws: AuthError.notAuthorized) {
            try await service.createUser(NewUser(firstName: "X", lastName: "Y", role: .commander, password: nil))
        }
        try service.updateProfile(commander.id) { $0.callsign = " ELRD 2 " }
        #expect(service.currentUser?.callsign == "ELRD 2")
    }

    @Test func deactivatedUsersCannotLogInButRemainKnown() async throws {
        let service = try AuthFixture().makeService()
        try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        let commander = try await service.createUser(NewUser(firstName: "Max", lastName: "Muster", role: .commander, password: nil))
        try service.deactivate(commander.id)
        #expect(!service.directory.activeUsers.contains { $0.id == commander.id })
        #expect(service.directory.user(commander.id)?.displayName == "Max Muster")
        await #expect(throws: AuthError.userDeactivated) { try await service.login(commander.id, password: nil) }
    }

    @Test func passwordChangeAndAdminReset() async throws {
        let service = try AuthFixture().makeService()
        let admin = try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        let commander = try await service.createUser(NewUser(firstName: "Max", lastName: "Muster", role: .commander, password: "max123"))

        try await service.resetPassword("neu456", for: commander.id)
        await #expect(throws: AuthError.invalidCredentials) { try await service.changePassword(current: "falsch1", new: "geheim9") }
        try await service.changePassword(current: "geheim1", new: "geheim9")
        await #expect(throws: AuthError.passwordRequiredForAdmin) { try await service.resetPassword(nil, for: admin.id) }

        try service.logout()
        try await service.login(commander.id, password: "neu456")
        await #expect(throws: AuthError.notAuthorized) { try await service.resetPassword("abcdef", for: admin.id) }
        try service.logout()
        try await service.login(admin.id, password: "geheim9")
    }

    @Test func sessionSurvivesRestart() async throws {
        let fixture = AuthFixture()
        let admin = try await fixture.makeService().createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")

        let restarted = try fixture.makeService()
        #expect(restarted.currentUser == nil)
        let restored = try restarted.restoreSession()
        #expect(restored?.id == admin.id)

        try restarted.logout()
        #expect(try fixture.makeService().restoreSession() == nil)
    }

    @Test func weakHashIsUpgradedOnLogin() async throws {
        let fixture = AuthFixture()
        let weakService = try UserService(
            repository: fixture.repository,
            secureStore: fixture.secureStore,
            provider: LocalAuthProvider(hasher: PasswordHasher(iterations: 100))
        )
        let admin = try await weakService.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        #expect(admin.passwordHash?.iterations == 100)

        let service = try fixture.makeService()
        try await service.login(admin.id, password: "geheim1")
        #expect(service.directory.user(admin.id)?.passwordHash?.iterations == 1_000)
    }

    @Test func backendLinkIsOptional() async throws {
        let service = try AuthFixture().makeService()
        let admin = try await service.createInitialAdmin(firstName: "A", lastName: "B", password: "geheim1")
        try service.linkRemoteAccount(" elrd-4711 ", for: admin.id)
        #expect(service.currentUser?.remoteAccountID == "elrd-4711")
        #expect(service.currentUser?.isLinkedToBackend == true)
        try service.linkRemoteAccount(nil, for: admin.id)
        #expect(service.currentUser?.remoteLinkedAt == nil)
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
