import Foundation
import ELRDDomain

// MARK: - Teilnehmer im geteilten Einsatz (Schritt 89, E103)

/// Trägt die angemeldete Person als Teilnehmer ein (beim Öffnen eines geteilten
/// Einsatzes). Ohne Änderung, wenn sie schon mit gleichem Namen eingetragen ist.
public struct JoinAsParticipant: MissionCommand {
    public init() {}

    public func execute(_ draft: inout MissionDraft) throws {
        let session = draft.context.session
        guard let userID = session.userID else { return }
        let existing = draft.mission.participant(userID)
        if let existing, existing.displayName == session.displayName { return }
        var participant = existing ?? MissionParticipant(userID: userID, displayName: session.displayName, joinedAt: draft.context.now)
        participant.displayName = session.displayName
        let entry = participant
        try draft.updateMission { $0.upsertParticipant(entry) }
        if existing == nil {
            draft.log(.mission, "\(session.displayName) nimmt am Einsatz teil", subject: .mission(draft.missionID))
        }
    }
}

/// Teilnehmer wählt seinen Abschnitt selbst (`nil` = keiner).
public struct ChooseOwnSection: MissionCommand {
    public let sectionID: SectionID?

    public init(_ sectionID: SectionID?) {
        self.sectionID = sectionID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let session = draft.context.session
        guard let userID = session.userID else { throw CommandError.invalid("Bitte zuerst anmelden.") }
        var participant = draft.mission.participant(userID)
            ?? MissionParticipant(userID: userID, displayName: session.displayName, joinedAt: draft.context.now)
        guard participant.sectionID != sectionID else { return }
        var name = "keinen Abschnitt"
        if let sectionID {
            guard let section = draft.get(MissionSection.self, id: sectionID), !section.metadata.isDeleted else {
                throw CommandError.notFound(.section)
            }
            name = "Abschnitt „\(section.name)“"
        }
        participant.sectionID = sectionID
        let entry = participant
        try draft.updateMission { $0.upsertParticipant(entry) }
        draft.log(.section, "\(session.displayName) führt \(name)", subject: .mission(draft.missionID))
    }
}

/// Einsatzleitung vergibt Rechte je Teilnehmer.
public struct SetParticipantPermission: MissionCommand {
    public let participantID: UUID
    public let permission: ParticipantPermission

    public init(participantID: UUID, permission: ParticipantPermission) {
        self.participantID = participantID
        self.permission = permission
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard draft.mission.commanderID == draft.context.session.userID else {
            throw CommandError.invalid("Rechte vergibt nur die Einsatzleitung.")
        }
        guard var participant = draft.mission.participants?.first(where: { $0.id == participantID }) else {
            throw CommandError.invalid("Teilnehmer nicht gefunden.")
        }
        guard participant.permission != permission else { return }
        participant.permission = permission
        let entry = participant
        try draft.updateMission { $0.upsertParticipant(entry) }
        draft.log(.mission, "Rechte für \(entry.displayName): \(permission.displayName)", subject: .mission(draft.missionID))
    }
}

/// Prüft nach jeder Aktion, ob die angemeldete Person sie ausführen durfte (E103).
///
/// Schutz gegen Versehen, nicht gegen Manipulation: CloudKit selbst kennt nur
/// „Lesen und Schreiben“ für alle Teilnehmer.
enum AccessPolicy {
    static func check(_ draft: MissionDraft, before mission: Mission) throws {
        guard let userID = draft.context.session.userID else { return }
        let permission = mission.permission(of: userID)
        guard permission != .full else { return }

        try checkMission(draft, before: mission, userID: userID)
        guard draft.mapObjects.changes().isEmpty else { throw denied(permission) }

        switch permission {
        case .full:
            return
        case .readOnly:
            guard draft.sections.changes().isEmpty, draft.units.changes().isEmpty,
                  draft.patients.changes().isEmpty, draft.journal.changes().isEmpty else {
                throw denied(permission)
            }
        case .ownSection:
            // Ohne gewählten Abschnitt gilt der Stand nach der Aktion (Abschnitt gerade gewählt).
            guard let own = mission.ownSection(of: userID) ?? draft.mission.ownSection(of: userID) else {
                if draft.sections.changes().isEmpty, draft.units.changes().isEmpty, draft.patients.changes().isEmpty { return }
                throw CommandError.invalid("Zuerst unter „Führung und Kräfte“ den eigenen Abschnitt wählen.")
            }
            let patientsOK = draft.patients.changes().allSatisfy { $0.old?.sectionID == own || $0.new.sectionID == own }
            let unitsOK = draft.units.changes().allSatisfy { $0.old?.sectionID == own || $0.new.sectionID == own }
            let sectionsOK = draft.sections.changes().allSatisfy { $0.new.id == own }
            guard patientsOK, unitsOK, sectionsOK else { throw denied(permission) }
        }
    }

    /// Am Einsatz selbst darf nur der eigene Teilnehmer-Eintrag geändert werden –
    /// ohne die eigenen Rechte.
    private static func checkMission(_ draft: MissionDraft, before mission: Mission, userID: UserID) throws {
        for change in draft.missions.changes() {
            guard let old = change.old else { throw denied(mission.permission(of: userID)) }
            var oldRest = old
            var newRest = change.new
            oldRest.participants = old.participants?.filter { $0.id != userID.rawValue }
            newRest.participants = change.new.participants?.filter { $0.id != userID.rawValue }
            // Offene Punkte abhaken darf jeder (Schritt 96).
            oldRest.acknowledgedItems = nil
            newRest.acknowledgedItems = nil
            newRest.metadata = oldRest.metadata
            if (oldRest.participants ?? []).isEmpty { oldRest.participants = nil }
            if (newRest.participants ?? []).isEmpty { newRest.participants = nil }
            let samePermission = old.participant(userID)?.permission == change.new.participant(userID)?.permission
                || old.participant(userID) == nil
            guard oldRest == newRest, samePermission else { throw denied(mission.permission(of: userID)) }
        }
    }

    private static func denied(_ permission: ParticipantPermission) -> CommandError {
        switch permission {
        case .readOnly: .invalid("Sie haben in diesem Einsatz nur Leserechte. Die Einsatzleitung kann das ändern.")
        default: .invalid("Sie dürfen nur Ihren eigenen Abschnitt bearbeiten. Die Einsatzleitung kann das ändern.")
        }
    }
}

// MARK: - Offene Punkte abhaken (Schritt 96)

/// Offenen Punkt als „zur Kenntnis genommen“ abhaken. `description` steht im
/// Protokoll (ohne Patientennamen, z. B. „Nachsichtung fällig – Patient A-3“).
public struct AcknowledgeOpenItem: MissionCommand {
    public let itemID: String
    public let description: String

    public init(itemID: String, description: String) {
        self.itemID = itemID
        self.description = description
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard !(draft.mission.acknowledgedItems ?? []).contains(where: { $0.id == itemID }) else { return }
        let entry = AcknowledgedOpenItem(id: itemID, at: draft.context.now, by: draft.context.session.displayName)
        try draft.updateMission { mission in
            mission.acknowledgedItems = (mission.acknowledgedItems ?? []) + [entry]
        }
        draft.log(.mission, "Offener Punkt zur Kenntnis genommen: \(description)", subject: .mission(draft.missionID))
    }
}

/// Abgehakte Punkte wieder anzeigen.
public struct RestoreOpenItems: MissionCommand {
    public init() {}

    public func execute(_ draft: inout MissionDraft) throws {
        guard !(draft.mission.acknowledgedItems ?? []).isEmpty else { return }
        try draft.updateMission { $0.acknowledgedItems = nil }
        draft.log(.mission, "Abgehakte offene Punkte wieder angezeigt", subject: .mission(draft.missionID))
    }
}
