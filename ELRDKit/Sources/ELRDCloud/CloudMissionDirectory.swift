import Foundation
import ELRDDomain

/// Verbindung eines Einsatzes mit iCloud.
public struct CloudMissionLink: Codable, Hashable, Sendable {
    public var zone: CloudZone
    /// Einladungslink. Beim Eigentümer der eigene, bei Beigetretenen der, über den
    /// sie kamen (mit „Jeder mit dem Link“ können auch sie weitere einladen).
    public var shareURL: URL?
    public var linkedAt: Date

    public init(zone: CloudZone, shareURL: URL?, linkedAt: Date) {
        self.zone = zone
        self.shareURL = shareURL
        self.linkedAt = linkedAt
    }

    public var isOwner: Bool { zone.scope == .owned }
}

/// Mit iCloud verbundene Einsätze dieses Geräts (Gerätedokument `cloudMissions`).
public struct CloudMissionDirectory: Codable, Hashable, Sendable {
    /// iCloud-Konto, dem die Verbindungen und Stände gehören.
    public var accountID: String?
    private var links: [String: CloudMissionLink] = [:]

    public init(accountID: String? = nil) {
        self.accountID = accountID
    }

    public subscript(mission: MissionID) -> CloudMissionLink? {
        get { links[mission.rawValue.uuidString] }
        set { links[mission.rawValue.uuidString] = newValue }
    }

    public var missions: [MissionID] {
        links.keys.compactMap(MissionID.init(uuidString:)).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    public var isEmpty: Bool { links.isEmpty }

    public mutating func removeAll() {
        links.removeAll()
    }
}
