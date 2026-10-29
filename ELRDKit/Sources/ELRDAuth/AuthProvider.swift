import Foundation
import ELRDDomain

/// Prüft Anmeldedaten. Heute nur lokal; ein `RemoteAuthProvider` (ELRD-Backend)
/// kann später ergänzt werden, ohne den `UserService` zu ändern.
public protocol AuthProvider: Sendable {
    /// Prüft das Passwort gegen den gespeicherten Stand des Benutzers.
    func verify(password: String?, for user: UserAccount) async -> AuthVerification
}

public struct AuthVerification: Sendable {
    public let isValid: Bool
    /// Neuer Hash, falls der gespeicherte schwächer ist als die aktuelle Einstellung.
    public let upgradedHash: PasswordHash?

    public init(isValid: Bool, upgradedHash: PasswordHash? = nil) {
        self.isValid = isValid
        self.upgradedHash = upgradedHash
    }
}

/// Lokale Prüfung gegen den gespeicherten Passwort-Hash.
public struct LocalAuthProvider: AuthProvider {
    public let hasher: PasswordHasher

    public init(hasher: PasswordHasher = PasswordHasher()) {
        self.hasher = hasher
    }

    public func verify(password: String?, for user: UserAccount) async -> AuthVerification {
        guard let stored = user.passwordHash else {
            // Benutzer ohne Passwort: Anmeldung nur ohne Eingabe gültig.
            return AuthVerification(isValid: (password ?? "").isEmpty)
        }
        guard let password, !password.isEmpty else { return AuthVerification(isValid: false) }
        let hasher = hasher
        // PBKDF2 ist absichtlich rechenintensiv – nicht auf dem Main Thread.
        return await Task.detached(priority: .userInitiated) {
            guard hasher.verify(password, against: stored) else { return AuthVerification(isValid: false) }
            let upgrade = hasher.needsRehash(stored) ? try? hasher.hash(password) : nil
            return AuthVerification(isValid: true, upgradedHash: upgrade)
        }.value
    }

    /// Erzeugt einen Hash im Hintergrund.
    func makeHash(_ password: String) async throws -> PasswordHash {
        let hasher = hasher
        return try await Task.detached(priority: .userInitiated) { try hasher.hash(password) }.value
    }
}
