import Foundation

/// Nachricht im Einsatz (ELRDRG: „Nachrichten“ mit Badge).
///
/// Heute erzeugt die App Hinweise selbst (z. B. „Lagekartenausschnitt wurde dem
/// Tagebuch hinzugefügt“). Im Mehrbenutzer-Modus kommen Nachrichten anderer
/// Benutzer hinzu; dafür ist `senderID` vorgesehen.
public struct MissionMessage: VersionedEntity, MissionScoped {
    public let id: MessageID
    public let missionID: MissionID
    public var metadata: EntityMetadata

    public var sentAt: Date
    /// Anzeigename des Absenders (z. B. Benutzername oder „ELRD“).
    public var senderName: String
    /// Absender, falls ein Benutzer (nicht die App selbst) die Nachricht verfasst hat.
    public var senderID: UserID?
    public var text: String
    public var kind: MessageKind
    public private(set) var acknowledgedAt: Date?
    public private(set) var acknowledgedBy: UserID?

    public init(
        id: MessageID = MessageID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        sentAt: Date,
        senderName: String,
        senderID: UserID? = nil,
        text: String,
        kind: MessageKind = .info
    ) {
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.sentAt = sentAt
        self.senderName = senderName
        self.senderID = senderID
        self.text = text
        self.kind = kind
        self.acknowledgedAt = nil
        self.acknowledgedBy = nil
    }
}

/// Art einer Nachricht; bestimmt Symbol und Hervorhebung.
public enum MessageKind: Int, CaseIterable, Codable, Sendable, DisplayNamed {
    case info = 0
    case warning = 1
    /// Von der App erzeugter Hinweis.
    case system = 2

    public var displayName: String {
        switch self {
        case .info: "Information"
        case .warning: "Warnung"
        case .system: "Systemhinweis"
        }
    }
}

public extension MissionMessage {
    var isAcknowledged: Bool { acknowledgedAt != nil }

    /// Quittiert die Nachricht. Bereits quittierte Nachrichten bleiben unverändert.
    mutating func acknowledge(by user: UserID?, at date: Date) {
        guard acknowledgedAt == nil else { return }
        acknowledgedAt = date
        acknowledgedBy = user
    }

    /// Anzahl unquittierter Nachrichten (für das Badge).
    static func unacknowledgedCount(in messages: some Sequence<MissionMessage>) -> Int {
        messages.active.filter { !$0.isAcknowledged }.count
    }

    /// Neueste zuerst.
    static func newestFirst(_ messages: some Sequence<MissionMessage>) -> [MissionMessage] {
        messages.active.sorted { $0.sentAt > $1.sentAt }
    }
}
