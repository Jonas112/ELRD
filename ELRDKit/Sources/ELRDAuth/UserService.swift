import Foundation
import Observation
import ELRDDomain
import ELRDPersistence

/// Angaben für einen neuen Benutzer.
public struct NewUser: Sendable {
    public var firstName: String
    public var lastName: String
    public var callsign: String
    public var email: String
    public var phone: String
    public var role: UserRole
    /// `nil` oder leer = ohne Passwort (nur für Einsatzleiter).
    public var password: String?

    public init(
        firstName: String,
        lastName: String,
        callsign: String = "",
        email: String = "",
        phone: String = "",
        role: UserRole,
        password: String?
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.callsign = callsign
        self.email = email
        self.phone = phone
        self.role = role
        self.password = password
    }
}

/// Benutzerverwaltung und Anmeldung.
///
/// Regeln:
/// - Passwörter nur als PBKDF2-Hash (E6); Administratoren immer mit Passwort.
/// - Es bleibt immer mindestens ein aktiver Administrator.
/// - Nach `maxFailedAttempts` Fehlversuchen wird gesperrt, mit wachsender Dauer.
/// - Benutzer werden nur deaktiviert, nie gelöscht (Namen in Einsätzen bleiben).
@MainActor
@Observable
public final class UserService {
    public private(set) var directory: UserDirectory
    public private(set) var currentUser: UserAccount?

    @ObservationIgnored private let repository: any DocumentRepository
    @ObservationIgnored private let secureStore: any SecureStore
    @ObservationIgnored private let provider: LocalAuthProvider
    @ObservationIgnored private let now: () -> Date

    public static let maxFailedAttempts = 5
    static let baseLockout: TimeInterval = 30
    static let maxLockout: TimeInterval = 15 * 60
    static let sessionKey = "session.currentUserID"

    public init(
        repository: any DocumentRepository,
        secureStore: any SecureStore,
        provider: LocalAuthProvider = LocalAuthProvider(),
        now: @escaping () -> Date = Date.init
    ) throws {
        self.repository = repository
        self.secureStore = secureStore
        self.provider = provider
        self.now = now
        self.directory = try repository.document(UserDirectory.self, key: .users) ?? UserDirectory()
        self.currentUser = nil
    }

    /// Noch kein Benutzer angelegt → Einrichtung (Onboarding) nötig.
    public var needsInitialSetup: Bool { directory.users.isEmpty }

    // MARK: Einrichtung und Verwaltung

    /// Legt beim ersten Start den Administrator an und meldet ihn an.
    @discardableResult
    public func createInitialAdmin(firstName: String, lastName: String, callsign: String = "", password: String) async throws -> UserAccount {
        guard needsInitialSetup else { throw AuthError.alreadyInitialized }
        let user = try await makeUser(NewUser(firstName: firstName, lastName: lastName, callsign: callsign, role: .admin, password: password))
        var updated = directory
        updated.users.append(user)
        try save(updated)
        try startSession(user.id)
        return user
    }

    /// Legt einen weiteren Benutzer an (nur Administratoren).
    @discardableResult
    public func createUser(_ request: NewUser) async throws -> UserAccount {
        try requireAdmin()
        let user = try await makeUser(request)
        var updated = directory
        updated.users.append(user)
        try save(updated)
        return user
    }

    /// Ändert Name, Funkrufname, Kontaktdaten. Eigene Daten darf jeder ändern, fremde nur Administratoren.
    public func updateProfile(_ userID: UserID, _ change: (inout ProfileFields) -> Void) throws {
        try requireSelfOrAdmin(userID)
        try modify(userID) { user in
            var fields = ProfileFields(user)
            change(&fields)
            user.firstName = fields.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            user.lastName = fields.lastName.trimmingCharacters(in: .whitespacesAndNewlines)
            user.callsign = fields.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
            user.email = fields.email.trimmingCharacters(in: .whitespacesAndNewlines)
            user.phone = fields.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Ändert die Rolle (nur Administratoren). Der letzte Administrator bleibt Administrator.
    public func setRole(_ role: UserRole, for userID: UserID) throws {
        try requireAdmin()
        guard let user = directory.user(userID) else { throw AuthError.userNotFound }
        if user.isAdmin && role != .admin && directory.activeAdminCount <= 1 { throw AuthError.lastAdmin }
        if role == .admin && !user.hasPassword { throw AuthError.passwordRequiredForAdmin }
        try modify(userID) { $0.role = role }
    }

    /// Eigenes Passwort ändern (altes Passwort nötig).
    public func changePassword(current: String?, new: String?) async throws {
        guard let user = currentUser else { throw AuthError.notLoggedIn }
        guard await provider.verify(password: current, for: user).isValid else { throw AuthError.invalidCredentials }
        try await setPassword(new, for: user.id)
    }

    /// Passwort eines anderen Benutzers zurücksetzen (nur Administratoren).
    public func resetPassword(_ new: String?, for userID: UserID) async throws {
        try requireAdmin()
        try await setPassword(new, for: userID)
    }

    /// Deaktiviert einen Benutzer (nur Administratoren). Er erscheint nicht mehr
    /// zur Anmeldung, bleibt aber für Einsätze und Berichte erhalten.
    public func deactivate(_ userID: UserID) throws {
        try requireAdmin()
        guard let user = directory.user(userID) else { throw AuthError.userNotFound }
        if user.isAdmin && directory.activeAdminCount <= 1 { throw AuthError.lastAdmin }
        let date = now()
        try modify(userID) { $0.deactivatedAt = date }
        if currentUser?.id == userID { try logout() }
    }

    /// Verknüpft den Benutzer mit einem Backend-Konto (Vorbereitung, E5).
    public func linkRemoteAccount(_ remoteID: String?, for userID: UserID) throws {
        try requireSelfOrAdmin(userID)
        let date = now()
        let trimmed = remoteID?.trimmingCharacters(in: .whitespacesAndNewlines)
        try modify(userID) { user in
            user.remoteAccountID = (trimmed?.isEmpty ?? true) ? nil : trimmed
            user.remoteLinkedAt = user.remoteAccountID == nil ? nil : date
        }
    }

    // MARK: Anmeldung

    /// Meldet einen Benutzer an. Fehlversuche führen ab dem fünften zu einer Sperre.
    @discardableResult
    public func login(_ userID: UserID, password: String?) async throws -> UserAccount {
        guard let user = directory.user(userID) else { throw AuthError.invalidCredentials }
        guard user.isActive else { throw AuthError.userDeactivated }
        if let lockedUntil = user.lockedUntil, lockedUntil > now() { throw AuthError.lockedOut(until: lockedUntil) }

        let verification = await provider.verify(password: password, for: user)
        let date = now()
        guard verification.isValid else {
            var lockUntil: Date?
            try modify(userID) { account in
                account.failedLoginCount += 1
                let excess = account.failedLoginCount - Self.maxFailedAttempts
                if excess >= 0 {
                    let duration = min(Self.baseLockout * pow(2, Double(excess)), Self.maxLockout)
                    account.lockedUntil = date.addingTimeInterval(duration)
                    lockUntil = account.lockedUntil
                }
            }
            if let lockUntil { throw AuthError.lockedOut(until: lockUntil) }
            throw AuthError.invalidCredentials
        }

        try modify(userID) { account in
            account.failedLoginCount = 0
            account.lockedUntil = nil
            account.lastLoginAt = date
            if let upgraded = verification.upgradedHash { account.passwordHash = upgraded }
        }
        try startSession(userID)
        return directory.user(userID) ?? user
    }

    public func logout() throws {
        currentUser = nil
        try secureStore.set(nil as Data?, for: Self.sessionKey)
    }

    /// Stellt die letzte Anmeldung nach einem App-Neustart wieder her.
    /// Gelöschte oder deaktivierte Benutzer werden dabei abgemeldet.
    @discardableResult
    public func restoreSession() throws -> UserAccount? {
        guard let text = try secureStore.string(for: Self.sessionKey),
              let id = UserID(uuidString: text),
              let user = directory.user(id), user.isActive else {
            try logout()
            return nil
        }
        currentUser = user
        return user
    }

    // MARK: Intern

    private func makeUser(_ request: NewUser) async throws -> UserAccount {
        let password = request.password ?? ""
        if request.role == .admin && password.isEmpty { throw AuthError.passwordRequiredForAdmin }
        var user = UserAccount(
            firstName: request.firstName,
            lastName: request.lastName,
            callsign: request.callsign,
            email: request.email,
            phone: request.phone,
            role: request.role,
            createdAt: now()
        )
        if !password.isEmpty {
            try PasswordPolicy.validate(password)
            user.passwordHash = try await provider.makeHash(password)
        }
        return user
    }

    private func setPassword(_ new: String?, for userID: UserID) async throws {
        guard let user = directory.user(userID) else { throw AuthError.userNotFound }
        let password = new ?? ""
        if password.isEmpty {
            if user.isAdmin { throw AuthError.passwordRequiredForAdmin }
            try modify(userID) { $0.passwordHash = nil }
            return
        }
        try PasswordPolicy.validate(password)
        let hash = try await provider.makeHash(password)
        try modify(userID) { account in
            account.passwordHash = hash
            account.failedLoginCount = 0
            account.lockedUntil = nil
        }
    }

    private func modify(_ userID: UserID, _ change: (inout UserAccount) -> Void) throws {
        guard let index = directory.users.firstIndex(where: { $0.id == userID }) else { throw AuthError.userNotFound }
        var updated = directory
        change(&updated.users[index])
        try save(updated)
    }

    /// Speichert zuerst, übernimmt dann – schlägt Speichern fehl, bleibt der alte Stand.
    private func save(_ updated: UserDirectory) throws {
        var next = updated
        next.revision += 1
        try repository.saveDocument(next, key: .users, at: now())
        directory = next
        if let current = currentUser { currentUser = next.user(current.id) }
    }

    private func startSession(_ userID: UserID) throws {
        try secureStore.set(userID.rawValue.uuidString, for: Self.sessionKey)
        currentUser = directory.user(userID)
    }

    private func requireAdmin() throws {
        guard let user = currentUser else { throw AuthError.notLoggedIn }
        guard user.isAdmin else { throw AuthError.notAuthorized }
    }

    private func requireSelfOrAdmin(_ userID: UserID) throws {
        guard let user = currentUser else { throw AuthError.notLoggedIn }
        guard user.isAdmin || user.id == userID else { throw AuthError.notAuthorized }
    }
}

/// Bearbeitbare Profilfelder.
public struct ProfileFields: Sendable {
    public var firstName: String
    public var lastName: String
    public var callsign: String
    public var email: String
    public var phone: String

    init(_ user: UserAccount) {
        firstName = user.firstName
        lastName = user.lastName
        callsign = user.callsign
        email = user.email
        phone = user.phone
    }
}

public extension DocumentKey {
    /// Benutzer des Geräts (`UserDirectory`).
    static let users = DocumentKey(rawValue: "users")
}
