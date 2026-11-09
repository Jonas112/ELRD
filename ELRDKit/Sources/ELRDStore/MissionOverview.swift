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
    /// Übung (Schritt 88).
    public let isExercise: Bool
    /// Personendaten entfernt (Schritt 102).
    public let isAnonymized: Bool
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
        isExercise = mission.isExerciseMission
        isAnonymized = mission.anonymizedAt != nil
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

// MARK: - Statistik (Schritt 100)

/// Kennzahlen über alle Einsätze eines Jahres. Übungen werden getrennt gezählt und
/// fließen nicht in die Einsatzzahlen ein.
public struct MissionStatistics: Equatable, Sendable {
    public struct TypeCount: Equatable, Sendable {
        public let name: String
        public let missions: Int
        public let patients: Int
    }

    public let year: Int?
    public let missions: Int
    public let exercises: Int
    public let running: Int
    public let patients: Int
    public let triageCounts: [Sichtungskategorie: Int]
    /// Ø Dauer beendeter Einsätze in Minuten.
    public let averageMinutes: Int?
    public let longestMinutes: Int?
    /// Größter Einsatz (Patienten).
    public let largestPatients: Int
    public let byType: [TypeCount]
    /// Jahre mit Einsätzen, neueste zuerst.
    public let years: [Int]

    /// `year == nil`: alle Jahre.
    public init(summaries: [MissionSummary], year: Int?) {
        self.year = year
        years = Array(Set(summaries.map(\.year))).sorted(by: >)
        let inYear = summaries.filter { year == nil || $0.year == year }
        let real = inYear.filter { !$0.isExercise }
        missions = real.count
        exercises = inYear.count - real.count
        running = real.filter { !$0.isClosed }.count
        patients = real.reduce(0) { $0 + $1.patientCount }
        var counts: [Sichtungskategorie: Int] = [:]
        for summary in real {
            for (triage, count) in summary.triageCounts { counts[triage, default: 0] += count }
        }
        triageCounts = counts
        let durations = real.compactMap { summary -> Int? in
            guard let end = summary.endedAt else { return nil }
            return max(0, Int(end.timeIntervalSince(summary.startedAt) / 60))
        }
        averageMinutes = durations.isEmpty ? nil : Int((Double(durations.reduce(0, +)) / Double(durations.count)).rounded())
        longestMinutes = durations.max()
        largestPatients = real.map(\.patientCount).max() ?? 0
        byType = Dictionary(grouping: real) { $0.typeName ?? "Ohne Einsatzart" }
            .map { TypeCount(name: $0.key, missions: $0.value.count, patients: $0.value.reduce(0) { $0 + $1.patientCount }) }
            .sorted { ($0.missions, $1.name) > ($1.missions, $0.name) }
    }
}

// MARK: - Personensuche über alle Einsätze (Schritt 101)

public struct PersonSearchHit: Identifiable, Equatable, Sendable {
    public var id: String { "\(missionID.rawValue.uuidString)-\(whereabouts.id.rawValue.uuidString)" }
    public let missionID: MissionID
    public let missionNumber: String
    public let missionTitle: String
    public let startedAt: Date
    public let isExercise: Bool
    public let whereabouts: PatientWhereabouts
}

@MainActor
public enum PersonSearch {
    /// Sucht in allen (nicht gelöschten) Einsätzen nach Name, Nummer, Karte, Merkmalen;
    /// neueste Einsätze zuerst. Leere Suche → keine Treffer.
    public static func search(_ query: String, in repository: any EntityRepository, now: Date, limit: Int = 200) throws -> [PersonSearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return [] }
        var hits: [PersonSearchHit] = []
        for mission in try repository.missions().sorted(by: { $0.startedAt > $1.startedAt }) {
            let patients = try repository.entities(Patient.self, in: mission.id)
            guard !patients.isEmpty else { continue }
            let list = PatientWhereabouts.list(
                patients: patients,
                units: try repository.entities(MissionUnit.self, in: mission.id),
                sections: try repository.entities(MissionSection.self, in: mission.id),
                now: now
            )
            for entry in list where entry.matches(text) {
                hits.append(PersonSearchHit(
                    missionID: mission.id,
                    missionNumber: mission.displayNumber(),
                    missionTitle: mission.title,
                    startedAt: mission.startedAt,
                    isExercise: mission.isExerciseMission,
                    whereabouts: entry
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }
}

// MARK: - Datenschutz (Schritt 102)

public enum AnonymizationPolicy {
    /// Beendete, noch nicht anonymisierte Einsätze, deren Ende länger als `days` her ist.
    public static func due(_ summaries: [MissionSummary], days: Int, now: Date) -> [MissionID] {
        guard days > 0 else { return [] }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return summaries.filter { summary in
            guard summary.isClosed, !summary.isAnonymized, let end = summary.endedAt else { return false }
            return end < limit
        }.map(\.id)
    }
}
