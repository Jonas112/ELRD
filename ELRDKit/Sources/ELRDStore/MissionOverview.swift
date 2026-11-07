import Foundation
import ELRDDomain
import ELRDPersistence

/// Kurzfassung eines Einsatzes für die Einsatzliste.
public struct MissionSummary: Identifiable, Equatable, Sendable {
    public let id: MissionID
    /// „2026/12“
    public let displayNumber: String
    /// Kalenderjahr des Einsatzbeginns (für den Jahresfilter).
    public let year: Int
    public let title: String
    public let typeName: String?
    public let location: String
    public let dispatchNumber: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let isClosed: Bool
    /// Anzahl der (nicht gelöschten) Patienten.
    public let patientCount: Int
    public let triageCounts: [Sichtungskategorie: Int]
    /// Vorschaubild: markierter Eintrag, sonst erstes Foto, sonst letzter Kartenausschnitt.
    public let thumbnail: FileAttachment?

    public init(mission: Mission, patients: [Patient], journal: [JournalEntry] = [], calendar: Calendar = .current) {
        id = mission.id
        displayNumber = mission.displayNumber(calendar: calendar)
        year = calendar.component(.year, from: mission.startedAt)
        title = mission.title
        typeName = mission.type?.displayName
        location = mission.location
        dispatchNumber = mission.dispatchNumber
        startedAt = mission.startedAt
        endedAt = mission.endedAt
        isClosed = mission.isClosed
        let active = patients.active
        patientCount = active.count
        triageCounts = Patient.countsByTriage(active)
        thumbnail = JournalEntry.thumbnail(in: journal)
            ?? JournalEntry.chronological(journal).last { $0.origin == .mapSnapshot }?.firstImage
    }

    /// Dauer bis zum Ende bzw. bis `now`, solange der Einsatz läuft.
    public func duration(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

/// Filter der Einsatzliste: Jahr und Suche.
///
/// Laufende Einsätze werden immer gezeigt – egal welches Jahr oder welche Suche –,
/// damit man nachts nie „seinen“ Einsatz suchen muss.
public struct MissionListFilter: Equatable, Sendable {
    /// `false`: nur beendete Einsätze des aktuellen Jahres (wie ELRDRG).
    public var showsAllYears: Bool
    public var searchText: String

    public init(showsAllYears: Bool = false, searchText: String = "") {
        self.showsAllYears = showsAllYears
        self.searchText = searchText
    }

    public struct Result: Equatable, Sendable {
        /// Laufende Einsätze, neueste zuerst.
        public var running: [MissionSummary]
        /// Beendete Einsätze passend zum Filter, neueste zuerst.
        public var finished: [MissionSummary]
        /// Beendete Einsätze, die zur Suche passen, aber nur wegen des Jahres fehlen.
        public var hiddenByYear: Int
    }

    public func apply(to missions: [MissionSummary], now: Date, calendar: Calendar = .current) -> Result {
        let currentYear = calendar.component(.year, from: now)
        let newestFirst = missions.sorted { ($0.startedAt, $0.id.rawValue.uuidString) > ($1.startedAt, $1.id.rawValue.uuidString) }
        let running = newestFirst.filter { !$0.isClosed }
        let matching = newestFirst.filter { $0.isClosed && matches($0) }
        let finished = showsAllYears ? matching : matching.filter { $0.year == currentYear }
        return Result(running: running, finished: finished, hiddenByYear: matching.count - finished.count)
    }

    /// Jedes Suchwort muss vorkommen (Groß/klein und Akzente egal), in Titel,
    /// Einsatzart, Ort, Jahresnummer oder ILS-Nummer.
    public func matches(_ summary: MissionSummary) -> Bool {
        let words = searchText.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [summary.title, summary.typeName ?? "", summary.location, summary.displayNumber, summary.dispatchNumber ?? ""]
            .joined(separator: " ")
        return words.allSatisfy { word in
            haystack.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Liest die Einsatzliste aus dem Repository.
@MainActor
public enum MissionOverview {
    public static func load(from repository: any EntityRepository, calendar: Calendar = .current) throws -> [MissionSummary] {
        try repository.missions().map { mission in
            MissionSummary(
                mission: mission,
                patients: try repository.entities(Patient.self, in: mission.id),
                journal: try repository.entities(JournalEntry.self, in: mission.id),
                calendar: calendar
            )
        }
    }

    /// Gelöschte Einsätze (Papierkorb der Einsatzliste), zuletzt begonnene zuerst.
    public static func loadDeleted(from repository: any EntityRepository, calendar: Calendar = .current) throws -> [MissionSummary] {
        try repository.missions(includeDeleted: true).filter(\.isDeleted).map { mission in
            MissionSummary(
                mission: mission,
                patients: try repository.entities(Patient.self, in: mission.id),
                journal: try repository.entities(JournalEntry.self, in: mission.id),
                calendar: calendar
            )
        }
    }
}
