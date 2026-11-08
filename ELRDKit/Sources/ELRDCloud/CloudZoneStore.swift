import Foundation
import ELRDDomain
import ELRDSync

// MARK: - Zone je Einsatz

/// Ablage eines Einsatzes in iCloud: eine eigene Zone.
///
/// Die Zone liegt in der privaten Datenbank des Kontos, das den Einsatz teilt
/// (`owned`). Wer über einen Link beitritt, sieht dieselbe Zone in seiner
/// geteilten Datenbank (`joined`), mit dem Konto des Eigentümers als `ownerName`.
public struct CloudZone: Hashable, Codable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// Eigene Zone (private Datenbank).
        case owned
        /// Zone eines anderen Kontos (geteilte Datenbank).
        case joined
    }

    public static let namePrefix = "elrd-mission-"
    /// Platzhalter von CloudKit für „das eigene Konto“ (`CKCurrentUserDefaultName`).
    public static let currentUser = "__defaultOwner__"

    public var scope: Scope
    public var zoneName: String
    public var ownerName: String

    public init(scope: Scope, zoneName: String, ownerName: String) {
        self.scope = scope
        self.zoneName = zoneName
        self.ownerName = ownerName
    }

    /// Eigene Zone für einen Einsatz. Der Name folgt fest aus der Einsatz-ID: Zwei
    /// Geräte desselben Kontos, die gleichzeitig teilen, landen in derselben Zone.
    public static func owned(_ mission: MissionID) -> CloudZone {
        CloudZone(scope: .owned, zoneName: namePrefix + mission.rawValue.uuidString.lowercased(), ownerName: currentUser)
    }

    /// Einsatz zu dieser Zone; `nil`, wenn die Zone nicht von ELRD stammt.
    public var missionID: MissionID? {
        guard zoneName.hasPrefix(Self.namePrefix) else { return nil }
        return MissionID(uuidString: String(zoneName.dropFirst(Self.namePrefix.count)))
    }
}

// MARK: - Datensätze

/// Ein Datensatz in der Zone. Ereignisse und Dateien werden nur angefügt, nie
/// geändert: Der Name ist fest (Ereignis-ID bzw. Prüfsumme), erneutes Speichern
/// überschreibt mit identischem Inhalt – damit ist Hochladen idempotent.
public struct CloudRecord: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case event = "ELRDEvent"
        case file = "ELRDFile"
    }

    public var name: String
    public var kind: Kind
    /// Inhalt. Liegt beim Dienst Ende-zu-Ende verschlüsselt (Ereignis: verschlüsseltes
    /// Feld, Datei: Asset). Beim Abholen von Änderungen bleibt er bei Dateien leer.
    public var payload: Data

    public init(name: String, kind: Kind, payload: Data) {
        self.name = name
        self.kind = kind
        self.payload = payload
    }

    public static func fileName(sha256: String) -> String { "file-" + sha256 }
}

/// Geänderte Datensätze seit einem Stand.
public struct CloudChangePage: Sendable, Equatable {
    public var records: [CloudRecord]
    /// Neuer Stand (undurchsichtig).
    public var token: Data?
    public var moreComing: Bool

    public init(records: [CloudRecord], token: Data?, moreComing: Bool) {
        self.records = records
        self.token = token
        self.moreComing = moreComing
    }
}

// MARK: - Fehler

/// Fehler des Cloud-Speichers, unabhängig von CloudKit-Fehlercodes.
public enum CloudStoreError: Error, Equatable, Sendable {
    /// Kein iCloud-Konto angemeldet oder iCloud eingeschränkt (MDM).
    case notSignedIn
    case network
    /// Dienst ausgelastet; frühestens nach so vielen Sekunden erneut.
    case retry(after: Double)
    /// Zone gibt es nicht (mehr).
    case zoneMissing
    case tokenExpired
    /// Keine Schreibrechte oder Freigabe entzogen.
    case permissionDenied
    case quotaExceeded
    /// iCloud-Schlüsselbund zurückgesetzt: verschlüsselte Daten nicht mehr lesbar.
    case keyReset
    /// Paket zu groß für einen Aufruf.
    case batchTooLarge
    /// Link ist keine ELRD-Freigabe oder nicht (mehr) gültig.
    case invalidShare
    /// Gleichzeitig von einem anderen Gerät geändert (z. B. Freigabe angelegt).
    case conflict
    case other(String)

    /// Übersetzung in den Vertrag des Abgleichs.
    public func syncError(scope: CloudZone.Scope) -> SyncError {
        switch self {
        case .notSignedIn: .unauthorized
        case .network: .offline
        case .retry(let seconds): .retryLater(seconds: seconds)
        case .zoneMissing: scope == .joined ? .missionNotShared : .server("Ablage in iCloud fehlt")
        case .tokenExpired: .cursorExpired
        case .permissionDenied: .missionNotShared
        case .quotaExceeded: .storageFull
        case .keyReset: .encryptionReset
        case .batchTooLarge: .server("Paket zu groß")
        case .invalidShare: .missionNotShared
        case .conflict: .retryLater(seconds: 1)
        case .other(let message): .server(message)
        }
    }
}

extension CloudStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Auf diesem Gerät ist kein iCloud-Konto angemeldet oder iCloud ist gesperrt."
        case .network: "Keine Verbindung zu iCloud."
        case .retry: "iCloud ist gerade ausgelastet. Es geht gleich automatisch weiter."
        case .zoneMissing: "Der Einsatz ist in iCloud nicht (mehr) vorhanden."
        case .tokenExpired: "Der Abgleich beginnt von vorn."
        case .permissionDenied: "Keine Berechtigung – die Freigabe wurde beendet oder ist nur zum Lesen."
        case .quotaExceeded: "Der iCloud-Speicher ist voll."
        case .keyReset: "Die Verschlüsselung in iCloud wurde zurückgesetzt."
        case .batchTooLarge: "Zu viele Änderungen auf einmal."
        case .invalidShare: "Dieser Link ist keine gültige ELRD-Einladung."
        case .conflict: "Gleichzeitig auf einem anderen Gerät geändert."
        case .other(let message): message
        }
    }
}

// MARK: - Schnittstelle

/// Zugriff auf den Cloud-Speicher (CloudKit), reduziert auf das, was der Abgleich
/// braucht. Die CloudKit-Umsetzung ist `CloudKitZoneStore`; Tests verwenden eine
/// Nachbildung, die Fehler und Überschneidungen gezielt erzeugen kann.
public protocol CloudZoneStore: Sendable {
    /// Kennung des angemeldeten iCloud-Kontos. Ändert sie sich, gehören die
    /// gespeicherten Stände einem anderen Konto und werden verworfen.
    func accountID() async throws -> String

    /// Legt die eigene Zone an; vorhandene Zone ist kein Fehler.
    func createZone(_ zone: CloudZone) async throws
    /// Eigene Zone: löschen. Fremde Zone: Teilnahme beenden. Fehlende Zone ist kein Fehler.
    func deleteZone(_ zone: CloudZone) async throws

    /// Speichert alle Datensätze oder keinen (atomar). Vorhandene werden überschrieben.
    func save(_ records: [CloudRecord], in zone: CloudZone) async throws
    /// Geänderte Datensätze seit `token` (`nil` = alle).
    func changes(in zone: CloudZone, since token: Data?, limit: Int) async throws -> CloudChangePage
    /// Welche der Namen in der Zone vorhanden sind (ohne Inhalt zu laden).
    func existing(_ names: [String], in zone: CloudZone) async throws -> Set<String>
    /// Ein Datensatz samt Inhalt; `nil`, wenn es ihn nicht gibt.
    func fetch(_ name: String, in zone: CloudZone) async throws -> CloudRecord?

    /// Gibt die eigene Zone frei („Jeder mit dem Link kann bearbeiten“) und liefert
    /// den Link. Besteht schon eine Freigabe (auch von einem anderen Gerät desselben
    /// Kontos gleichzeitig angelegt), kommt deren Link.
    func share(_ zone: CloudZone, title: String) async throws -> URL
    /// Beendet die Freigabe; alle Teilnehmenden verlieren den Zugriff.
    func stopSharing(_ zone: CloudZone) async throws
    /// Nimmt eine Einladung an und liefert die Zone.
    func accept(_ url: URL) async throws -> CloudZone

    /// Richtet stille Push-Mitteilungen bei Änderungen ein (idempotent).
    func subscribeToChanges() async throws
}
