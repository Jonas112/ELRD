import Foundation
import ELRDDomain

// MARK: - Nachrichten

/// Nachricht an alle im Einsatz (Absender: angemeldeter Benutzer). Heute auf dem
/// Gerät, mit dem Abgleich später auf allen Geräten.
public struct SendMessage: MissionCommand {
    public let text: String
    public let kind: MessageKind

    public init(_ text: String, kind: MessageKind = .info) {
        self.text = text
        self.kind = kind
    }

    public func execute(_ draft: inout MissionDraft) throws -> MissionMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommandError.invalid("Bitte einen Text eingeben.") }
        let session = draft.context.session
        var message = MissionMessage(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            sentAt: draft.context.now,
            senderName: session.displayName,
            senderID: session.userID,
            text: trimmed,
            kind: kind == .system ? .info : kind
        )
        // Eigene Nachrichten gelten für den Absender als gelesen.
        message.acknowledge(by: session.userID, at: draft.context.now)
        try draft.insert(message)
        draft.log(.message, kind == .warning ? "Warnung gesendet" : "Nachricht gesendet", subject: .message(message.id))
        return message
    }
}

/// Quittiert Nachrichten (`nil`: alle offenen).
public struct AcknowledgeMessages: MissionCommand {
    public let messageID: MessageID?

    public init(_ messageID: MessageID? = nil) {
        self.messageID = messageID
    }

    public static var allowedOnClosedMission: Bool { true }

    public func execute(_ draft: inout MissionDraft) throws {
        let open = draft.active(MissionMessage.self).filter { !$0.isAcknowledged && (messageID == nil || $0.id == messageID) }
        if let messageID, open.isEmpty, draft.get(MissionMessage.self, id: messageID) == nil {
            throw CommandError.notFound(.message)
        }
        let user = draft.context.session.userID
        let now = draft.context.now
        for message in open {
            try draft.update(MissionMessage.self, id: message.id) { $0.acknowledge(by: user, at: now) }
        }
    }
}
