import Foundation
import CommonCrypto
import Security

/// Gespeicherter Passwort-Hash (nie das Passwort selbst).
///
/// Algorithmus und Durchläufe werden mitgespeichert, damit später auf mehr
/// Durchläufe oder ein anderes Verfahren umgestellt werden kann: Beim nächsten
/// erfolgreichen Anmelden wird dann automatisch neu gehasht.
public struct PasswordHash: Hashable, Codable, Sendable {
    public let algorithm: String
    public let iterations: Int
    public let salt: Data
    public let hash: Data

    public static let pbkdf2SHA256 = "pbkdf2-sha256"
}

public enum PasswordHashError: Error, Equatable, Sendable {
    case randomGenerationFailed
    case derivationFailed(Int32)
}

/// PBKDF2-HMAC-SHA256 mit zufälligem Salt (CommonCrypto, keine Fremdbibliothek).
public struct PasswordHasher: Sendable {
    /// Empfehlung OWASP (2023) für PBKDF2-HMAC-SHA256.
    public static let recommendedIterations = 600_000

    public let iterations: Int
    let saltLength = 16
    let keyLength = 32

    /// - Parameter iterations: Nur Tests verwenden weniger Durchläufe.
    public init(iterations: Int = PasswordHasher.recommendedIterations) {
        self.iterations = max(iterations, 1)
    }

    public func hash(_ password: String) throws -> PasswordHash {
        let salt = try Self.randomBytes(saltLength)
        let derived = try derive(password, salt: salt, iterations: iterations)
        return PasswordHash(algorithm: PasswordHash.pbkdf2SHA256, iterations: iterations, salt: salt, hash: derived)
    }

    /// Prüft ein Passwort. Vergleich in konstanter Zeit.
    public func verify(_ password: String, against stored: PasswordHash) -> Bool {
        guard stored.algorithm == PasswordHash.pbkdf2SHA256,
              let derived = try? derive(password, salt: stored.salt, iterations: stored.iterations),
              derived.count == stored.hash.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(derived, stored.hash) { difference |= a ^ b }
        return difference == 0
    }

    /// Ob ein gespeicherter Hash schwächer ist als die aktuelle Einstellung.
    public func needsRehash(_ stored: PasswordHash) -> Bool {
        stored.algorithm != PasswordHash.pbkdf2SHA256 || stored.iterations < iterations
    }

    private func derive(_ password: String, salt: Data, iterations: Int) throws -> Data {
        // Unicode normalisieren: „ä“ als ein Zeichen oder als „a“ + Umlautpunkte ergibt denselben Hash.
        let passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard Int(status) == kCCSuccess else { throw PasswordHashError.derivationFailed(Int32(status)) }
        return derived
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PasswordHashError.randomGenerationFailed }
        return data
    }
}

/// Regeln für Passwörter.
public enum PasswordPolicy {
    /// Mindestlänge. Bewusst ohne Zeichenklassen-Pflicht: Im Einsatz zählt
    /// schnelle Eingabe; Schutz bieten Hash, Sperre nach Fehlversuchen und Gerätesperre.
    public static let minimumLength = 6

    public static func validate(_ password: String) throws {
        guard password.count >= minimumLength else {
            throw AuthError.passwordTooShort(minimum: minimumLength)
        }
    }
}

extension PasswordHashError: LocalizedError {
    public var errorDescription: String? {
        "Das Passwort konnte nicht sicher verarbeitet werden. Bitte erneut versuchen."
    }
}
