import Foundation

/// Rechte eines Teilnehmers im geteilten Einsatz (Schritt 89, E103).
public enum ParticipantPermission: String, Codable, Sendable, CaseIterable, Identifiable, DisplayNamed {
    /// Alles bearbeiten.
    case full
    /// Nur den eigenen Abschnitt (Patienten, Einheiten, Abschnittsdaten); Tagebuch und
    /// Nachrichten immer.
    case ownSection
    /// Nur ansehen; Nachrichten schreiben bleibt möglich.
    case readOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .full: "Alles"
        case .ownSection: "Eigener Abschnitt"
        case .readOnly: "Nur lesen"
        }
    }
}

/// Teilnehmer eines geteilten Einsatzes. Steht als Liste am Einsatz; der Abgleich
/// führt Listen mit Kennung elementweise zusammen – gleichzeitige Beitritte gehen
/// nicht verloren.
public struct MissionParticipant: Codable, Hashable, Sendable, Identifiable {
    /// = Benutzerkennung (je Person eindeutig, auch über Geräte).
    public let id: UUID
    public var displayName: String
    /// Gewählter Abschnitt (wählt der Teilnehmer selbst).
    public var sectionID: SectionID?
    public var permission: ParticipantPermission
    public var joinedAt: Date

    public init(userID: UserID, displayName: String, sectionID: SectionID? = nil, permission: ParticipantPermission = .full, joinedAt: Date) {
        id = userID.rawValue
        self.displayName = displayName
        self.sectionID = sectionID
        self.permission = permission
        self.joinedAt = joinedAt
    }

    public var userID: UserID { UserID(id) }

    // Unbekannte Rechte (neuere App) → „Nur lesen“ statt Lesefehler.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        sectionID = try container.decodeIfPresent(SectionID.self, forKey: .sectionID)
        permission = (try? container.decode(ParticipantPermission.self, forKey: .permission)) ?? .readOnly
        joinedAt = try container.decodeIfPresent(Date.self, forKey: .joinedAt) ?? .distantPast
    }
}

public extension Mission {
    func participant(_ userID: UserID?) -> MissionParticipant? {
        guard let userID else { return nil }
        return participants?.first { $0.id == userID.rawValue }
    }

    /// Rechte einer Person: Einsatzleitung und Nicht-Teilnehmer (lokal) dürfen alles.
    func permission(of userID: UserID?) -> ParticipantPermission {
        guard let userID else { return .full }
        if commanderID == userID { return .full }
        return participant(userID)?.permission ?? .full
    }

    /// Abschnitt, den die Person gewählt hat.
    func ownSection(of userID: UserID?) -> SectionID? {
        participant(userID)?.sectionID
    }

    /// Teilnehmer ändern (nur über Commands).
    mutating func upsertParticipant(_ participant: MissionParticipant) {
        var list = participants ?? []
        if let index = list.firstIndex(where: { $0.id == participant.id }) {
            list[index] = participant
        } else {
            list.append(participant)
        }
        participants = list
    }
}
