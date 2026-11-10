import Foundation

/// Eintrag im Einsatztagebuch (ELRDRG: „Dokumentation“).
public struct JournalEntry: VersionedEntity, MissionScoped {
    public let id: JournalEntryID
    public let missionID: MissionID
    public var metadata: EntityMetadata

    /// Laufende Nummer im Tagebuch mit Gerätepräfix, z. B. „A-7“.
    public var number: SerialNumber
    /// Zeitpunkt des Ereignisses. Kann vom Erfassungszeitpunkt (`metadata.createdAt`)
    /// abweichen, wenn nachträglich dokumentiert wird.
    public var occurredAt: Date
    public var text: String
    public var origin: JournalOrigin
    public private(set) var attachments: [FileAttachment]
    /// Bild dieses Eintrags dient als Vorschaubild des Einsatzes in der Einsatzliste.
    public var isMissionThumbnail: Bool
    /// Besondere Einträge (Lagemeldung, Checkliste, Übergabe); `nil` = normaler Eintrag.
    public var category: JournalCategory?
    /// Abgehakter Punkt der Checkliste (Schritt 76). Abhaken = Eintrag anlegen,
    /// zurücknehmen = Eintrag löschen – so kollidieren zwei Geräte nie.
    public var checklistItemID: String?
    /// Automatisches Lagebild (Schritt 109); `nil` = nein. Eigenes Feld statt neuer
    /// `JournalCategory`, damit ältere Apps die Einträge weiter lesen (E95).
    public var isSituationSnapshot: Bool?

    public init(
        id: JournalEntryID = JournalEntryID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        number: SerialNumber,
        occurredAt: Date,
        text: String,
        origin: JournalOrigin = .manual,
        attachments: [FileAttachment] = [],
        isMissionThumbnail: Bool = false
    ) {
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.number = number
        self.occurredAt = occurredAt
        self.text = text
        self.origin = origin
        self.attachments = []
        self.isMissionThumbnail = isMissionThumbnail
        for attachment in attachments { addAttachment(attachment) }
    }
}

/// Herkunft eines Tagebucheintrags.
public enum JournalOrigin: Int, CaseIterable, Codable, Sendable, DisplayNamed {
    /// Vom Benutzer erfasst.
    case manual = 0
    /// Von der App erzeugt, z. B. „Einsatz wurde beendet“.
    case automatic = 1
    /// Kartenausschnitt aus der Lagekarte.
    case mapSnapshot = 2

    public var displayName: String {
        switch self {
        case .manual: "Eintrag"
        case .automatic: "Automatisch"
        case .mapSnapshot: "Lagekarte"
        }
    }
}

/// Inhaltsart eines Eintrags für Symbol, Filter und Berichte.
/// Art eines besonderen Tagebucheintrags.
public enum JournalCategory: String, Codable, Sendable, CaseIterable {
    /// Lagemeldung (Schritt 67) – Grundlage der Erinnerung im Takt.
    case situationReport
    /// Abgehakter Punkt der Checkliste (Schritt 76).
    case checklist
    /// Übergabe an die Ablösung (Schritt 75).
    case handover
}

public enum JournalEntryKind: Int, CaseIterable, Sendable, DisplayNamed {
    case text = 0
    case photo = 1
    case audio = 2
    case video = 3

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .photo: "Foto"
        case .audio: "Audio"
        case .video: "Video"
        }
    }
}

// MARK: - Fachlogik

public extension JournalEntry {
    /// Art nach dem ersten Anhang; ohne Anhang ein Texteintrag.
    var kind: JournalEntryKind {
        switch attachments.first?.kind {
        case .photo?, .drawing?: .photo
        case .audio?: .audio
        case .video?: .video
        case nil: .text
        }
    }

    /// Erstes Bild (Foto oder Zeichnung), z. B. für Vorschau und Berichte.
    var firstImage: FileAttachment? {
        attachments.first { $0.kind == .photo || $0.kind == .drawing }
    }

    /// Ein Eintrag braucht Text oder mindestens einen Anhang.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    mutating func addAttachment(_ attachment: FileAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        attachments.append(attachment)
    }

    mutating func removeAttachment(_ id: AttachmentID) {
        attachments.removeAll { $0.id == id }
    }

    /// Nächste laufende Nummer für das Gerätepräfix (höchste eigene + 1).
    /// Gelöschte Einträge zählen mit, damit Nummern im Tagebuch nie doppelt vorkommen.
    static func nextNumber(prefix: String, existing entries: some Sequence<JournalEntry>) -> SerialNumber {
        SerialNumber.next(prefix: prefix, existing: entries.map(\.number))
    }

    /// Chronologisch nach Ereigniszeit, bei Gleichstand nach Nummer.
    static func chronological(_ entries: some Sequence<JournalEntry>) -> [JournalEntry] {
        entries.active.sorted { ($0.occurredAt, $0.number) < ($1.occurredAt, $1.number) }
    }

    /// Vorschaubild des Einsatzes wie ELRDRG: markierter Eintrag, sonst erstes Foto.
    static func thumbnail(in entries: some Sequence<JournalEntry>) -> FileAttachment? {
        let active = chronological(entries)
        if let marked = active.first(where: { $0.isMissionThumbnail })?.firstImage { return marked }
        return active.lazy.compactMap { entry in
            entry.attachments.first { $0.kind == .photo }
        }.first
    }
}
