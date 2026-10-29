import Foundation
import ELRDDomain

/// ELRDAuth – Benutzer und Anmeldung.
public enum ELRDAuthModule {
    public static let name = "ELRDAuth"
}

/// Rolle eines Benutzers.
public enum UserRole: String, Codable, Sendable, CaseIterable, DisplayNamed {
    /// Darf Benutzer, Stammdaten und Einstellungen verwalten.
    case admin
    /// Einsatzleiter: arbeitet in Einsätzen.
    case commander

    public var displayName: String {
        switch self {
        case .admin: "Administrator"
        case .commander: "Einsatzleiter"
        }
    }
}

/// Lokaler Benutzer des Geräts.
public struct UserAccount: Identifiable, Hashable, Codable, Sendable {
    public let id: UserID
    public var firstName: String
    public var lastName: String
    /// Funkrufname des Einsatzleiters (z. B. „ELRD 1“).
    public var callsign: String
    public var email: String
    public var phone: String
    public var role: UserRole
    /// `nil` = Anmeldung ohne Passwort (nur für Einsatzleiter erlaubt).
    public internal(set) var passwordHash: PasswordHash?
    /// Verknüpftes Konto im ELRD-Backend (optional, E5).
    public internal(set) var remoteAccountID: String?
    public internal(set) var remoteLinkedAt: Date?
    public let createdAt: Date
    /// Deaktivierte Benutzer bleiben gespeichert, damit Einsätze und Berichte ihre Namen behalten.
    public internal(set) var deactivatedAt: Date?
    public internal(set) var failedLoginCount: Int
    public internal(set) var lockedUntil: Date?
    public internal(set) var lastLoginAt: Date?

    public init(
        id: UserID = UserID(),
        firstName: String,
        lastName: String,
        callsign: String = "",
        email: String = "",
        phone: String = "",
        role: UserRole,
        createdAt: Date
    ) {
        self.id = id
        self.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.callsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        self.passwordHash = nil
        self.remoteAccountID = nil
        self.remoteLinkedAt = nil
        self.createdAt = createdAt
        self.deactivatedAt = nil
        self.failedLoginCount = 0
        self.lockedUntil = nil
        self.lastLoginAt = nil
    }

    public var isAdmin: Bool { role == .admin }
    public var isActive: Bool { deactivatedAt == nil }
    public var hasPassword: Bool { passwordHash != nil }
    public var isLinkedToBackend: Bool { remoteAccountID != nil }

    /// „Vorname Nachname“, sonst Funkrufname.
    public var displayName: String {
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? (callsign.isEmpty ? "Unbenannt" : callsign) : name
    }

    /// Anzeige wie ELRDRG in der Benutzerauswahl: „Funkrufname - Vorname Nachname“.
    public var listTitle: String {
        callsign.isEmpty ? displayName : "\(callsign) - \(displayName)"
    }
}

/// Alle Benutzer des Geräts (gespeichert als ein Dokument).
public struct UserDirectory: Hashable, Codable, Sendable {
    public internal(set) var users: [UserAccount]
    public internal(set) var revision: Int

    public init(users: [UserAccount] = [], revision: Int = 0) {
        self.users = users
        self.revision = revision
    }

    public var activeUsers: [UserAccount] {
        users.filter(\.isActive).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    public func user(_ id: UserID) -> UserAccount? {
        users.first { $0.id == id }
    }

    var activeAdminCount: Int { users.filter { $0.isActive && $0.isAdmin }.count }
}

/// Fehler bei Benutzerverwaltung und Anmeldung.
public enum AuthError: Error, Equatable, Sendable {
    case invalidCredentials
    case lockedOut(until: Date)
    case passwordTooShort(minimum: Int)
    case passwordRequiredForAdmin
    case lastAdmin
    case notAuthorized
    case userNotFound
    case userDeactivated
    case alreadyInitialized
    case notLoggedIn
}

extension AuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Benutzer oder Passwort ist falsch."
        case let .lockedOut(until):
            "Zu viele Fehlversuche. Anmelden wieder möglich ab \(until.formatted(date: .omitted, time: .standard))."
        case let .passwordTooShort(minimum): "Das Passwort muss mindestens \(minimum) Zeichen lang sein."
        case .passwordRequiredForAdmin: "Administratoren brauchen ein Passwort."
        case .lastAdmin: "Der letzte Administrator kann nicht entfernt oder herabgestuft werden."
        case .notAuthorized: "Dafür sind Administratorrechte nötig."
        case .userNotFound: "Benutzer nicht gefunden."
        case .userDeactivated: "Dieser Benutzer ist deaktiviert."
        case .alreadyInitialized: "Es gibt bereits Benutzer auf diesem Gerät."
        case .notLoggedIn: "Niemand ist angemeldet."
        }
    }
}
