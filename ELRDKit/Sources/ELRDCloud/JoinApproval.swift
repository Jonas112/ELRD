import Foundation
import CryptoKit
import ELRDDomain

// MARK: - Beitritt mit Genehmigung (Schritt 116, E119)
//
// Ist „Beitritt genehmigen“ eingestellt, gilt der Link nicht mehr für jeden
// (`publicPermission = .none`). Ablauf:
// 1. Wer beitreten will, legt eine Anfrage in der öffentlichen Datenbank des
//    Containers ab. Lesbar ist dort nur ein Hash des Links; Name und iCloud-Kennung
//    sind mit einem Schlüssel aus dem Link verschlüsselt – nur wer den Link kennt
//    (die Einsatzleitung), kann sie lesen.
// 2. Das Gerät der Einsatzleitung findet die Anfrage, zeigt sie an und nimmt die
//    Person bei „Zulassen“ als Teilnehmer in die iCloud-Freigabe auf.
// 3. Die Entscheidung liegt als eigener Datensatz bereit; das anfragende Gerät
//    sieht nach, tritt bei Zulassung bei und zieht die Anfrage zurück.
// Vor der Zulassung kommt kein Datensatz des Einsatzes auf das fremde Gerät.

/// Inhalt einer Beitrittsanfrage (verschlüsselt abgelegt).
public struct JoinRequestPayload: Codable, Hashable, Sendable {
    /// iCloud-Kennung (Benutzer-Datensatz) der anfragenden Person.
    public let userID: String
    public let displayName: String
    public let requestedAt: Date

    public init(userID: String, displayName: String, requestedAt: Date) {
        self.userID = userID
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestedAt = requestedAt
    }
}

/// Anfrage, wie sie in der öffentlichen Datenbank liegt.
public struct SealedJoinRequest: Hashable, Sendable {
    public let name: String
    public let shareKey: String
    public let sealed: Data

    public init(name: String, shareKey: String, sealed: Data) {
        self.name = name
        self.shareKey = shareKey
        self.sealed = sealed
    }
}

public enum JoinDecision: String, Codable, Sendable {
    case approved
    case denied
}

/// Offene Anfrage für die Einsatzleitung.
public struct JoinRequestItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let mission: MissionID
    public let payload: JoinRequestPayload
}

/// Eigene Anfrage, die auf Antwort wartet (Gerätedokument, übersteht Neustarts).
public struct PendingJoin: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case waiting
        case denied
    }

    public let url: URL
    public let requestName: String
    public let requestedAt: Date
    public var status: Status

    public var id: String { requestName }
}

/// Schlüssel und Namen – rein rechnerisch, ohne Netz (testbar).
public enum JoinSeal {
    /// Öffentlicher Schlüssel der Freigabe: Hash des Links (verrät den Link nicht).
    public static func shareKey(for url: URL) -> String {
        hex(SHA256.hash(data: Data(("elrd-share-v1|" + url.absoluteString).utf8)))
    }

    /// Fester Name je Freigabe und Person: erneutes Anfragen überschreibt.
    public static func requestName(shareKey: String, userID: String) -> String {
        "join-" + hex(SHA256.hash(data: Data((shareKey + "|" + userID).utf8))).prefix(40)
    }

    public static func decisionName(requestName: String) -> String {
        "decision-" + requestName.dropFirst("join-".count)
    }

    /// Verschlüsselt mit einem Schlüssel aus dem Link (AES-GCM).
    public static func seal(_ payload: JoinRequestPayload, url: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let box = try AES.GCM.seal(try encoder.encode(payload), using: key(for: url))
        guard let combined = box.combined else { throw CloudStoreError.other("Verschlüsselung fehlgeschlagen") }
        return combined
    }

    public static func open(_ sealed: Data, url: URL) throws -> JoinRequestPayload {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: key(for: url))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(JoinRequestPayload.self, from: plain)
    }

    private static func key(for url: URL) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(("elrd-join-v1|" + url.absoluteString).utf8)))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Speicher

public extension CloudZoneStore {
    // Standard für Speicher ohne Genehmigungen (Beispieldaten): wie bisher.
    func share(_ zone: CloudZone, title: String, requiresApproval: Bool) async throws -> URL {
        try await share(zone, title: title)
    }

    func currentUserID() async throws -> String { try await accountID() }
    func submitJoinRequest(_ request: SealedJoinRequest) async throws { throw CloudStoreError.other(Self.unsupported) }
    func joinRequests(shareKeys: [String]) async throws -> [SealedJoinRequest] { [] }
    func admit(userID: String, to zone: CloudZone) async throws { throw CloudStoreError.other(Self.unsupported) }
    func submitJoinDecision(_ decision: JoinDecision, requestName: String) async throws { throw CloudStoreError.other(Self.unsupported) }
    func joinDecision(requestName: String) async throws -> JoinDecision? { nil }
    func withdrawJoinRequest(name: String) async throws {}

    private static var unsupported: String { "Beitrittsanfragen sind hier nicht möglich." }
}
