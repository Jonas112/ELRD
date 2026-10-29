import Foundation

/// Eintrag im Einsatzprotokoll (ELRDRG: „Systemprotokoll“ / `Log`).
///
/// Lesbare Zusammenfassung einer Aktion, z. B. „Patient 3 wurde RTW 1 zugeordnet“.
/// Die Einträge werden ab Schritt 10 automatisch von der Command-Schicht
/// erzeugt – nie direkt aus der Oberfläche. Einträge werden nicht bearbeitet;
/// die Metadaten dienen nur der einheitlichen Speicherung und Synchronisation.
///
/// Datenschutz: Die Nachricht nennt Patienten über ihre Nummer, nie über Namen.
public struct MissionLogEntry: VersionedEntity, MissionScoped {
    public let id: LogEntryID
    public let missionID: MissionID
    public var metadata: EntityMetadata

    public let timestamp: Date
    public let category: LogCategory
    public let level: LogLevel
    public let message: String
    /// Betroffener Datensatz, damit die Oberfläche dorthin springen kann.
    public let subject: LogSubject?

    public init(
        id: LogEntryID = LogEntryID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        timestamp: Date,
        category: LogCategory,
        level: LogLevel = .user,
        message: String,
        subject: LogSubject? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.subject = subject
    }

    /// Wer die Aktion ausgelöst hat.
    public var authorID: UserID? { metadata.createdBy }
}

/// Fachbereich eines Protokolleintrags (für Filter und Berichte).
public enum LogCategory: Int, CaseIterable, Codable, Sendable, DisplayNamed {
    case mission = 0
    case patient = 1
    case unit = 2
    case section = 3
    case journal = 4
    case map = 5
    case message = 6

    public var displayName: String {
        switch self {
        case .mission: "Einsatz"
        case .patient: "Patienten"
        case .unit: "Einheiten"
        case .section: "Abschnitte"
        case .journal: "Tagebuch"
        case .map: "Lagekarte"
        case .message: "Nachrichten"
        }
    }
}

/// Sichtbarkeit. Rohwerte wie ELRDRG (`LogLevel`).
public enum LogLevel: Int, CaseIterable, Codable, Sendable, Comparable, DisplayNamed {
    /// Für alle Benutzer und im Bericht sichtbar.
    case user = 1
    /// Nur für Administratoren.
    case admin = 2
    /// Nur zur Fehlersuche.
    case developer = 3

    public var displayName: String {
        switch self {
        case .user: "Benutzer"
        case .admin: "Administrator"
        case .developer: "Entwickler"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Verweis auf den betroffenen Datensatz.
public enum LogSubject: Hashable, Codable, Sendable {
    case mission(MissionID)
    case patient(PatientID)
    case unit(UnitID)
    case section(SectionID)
    case journalEntry(JournalEntryID)
    case mapObject(MapObjectID)
    case message(MessageID)
}

public extension MissionLogEntry {
    /// Einträge bis einschließlich `maximumLevel`, chronologisch.
    static func visible(
        _ entries: some Sequence<MissionLogEntry>,
        maximumLevel: LogLevel = .user
    ) -> [MissionLogEntry] {
        entries.active
            .filter { $0.level <= maximumLevel }
            .sorted {
                // Bei gleichem Zeitstempel feste Reihenfolge statt zufälliger.
                ($0.timestamp, $0.id.rawValue.uuidString) < ($1.timestamp, $1.id.rawValue.uuidString)
            }
    }
}
