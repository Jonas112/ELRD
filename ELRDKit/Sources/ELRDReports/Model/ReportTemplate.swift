import Foundation
import ELRDDomain

/// Berichtsvorlage (Schritt 40): geordnete Kapitel mit Optionen plus Gestaltung.
/// Codable, damit sich Vorlagen speichern und teilen lassen (Schritt 45).
public struct ReportTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var chapters: [ReportChapter]
    public var theme: ReportTheme

    public init(id: UUID = UUID(), name: String, chapters: [ReportChapter], theme: ReportTheme = .standard) {
        self.id = id
        self.name = name
        self.chapters = chapters
        self.theme = theme
    }

    /// Eingeschaltete Kapitel in ihrer Reihenfolge.
    public var enabledChapters: [ReportChapter] { chapters.filter(\.isEnabled) }

    /// Gesamtbericht: alle Kapitel (Standard bis Schritt 45 die Vorlagen verwaltet).
    public static var full: ReportTemplate {
        ReportTemplate(name: "Gesamtbericht", chapters: ReportChapter.Kind.allCases.map { ReportChapter(kind: $0) })
    }
}

/// Ein Kapitel: Art, an/aus, Optionen.
public struct ReportChapter: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case missionInfo
        case organisation
        case patients
        case journal
        case log

        public var displayName: String {
            switch self {
            case .missionInfo: "Einsatzdaten"
            case .organisation: "Organisation"
            case .patients: "Patienten"
            case .journal: "Tagebuch"
            case .log: "Protokoll"
            }
        }
    }

    public var id: Kind { kind }
    public let kind: Kind
    public var isEnabled: Bool
    public var options: ReportChapterOptions

    public init(kind: Kind, isEnabled: Bool = true, options: ReportChapterOptions = ReportChapterOptions()) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.options = options
    }
}

/// Optionen aller Kapitel an einer Stelle (jedes Kapitel liest nur seine).
/// Neue Optionen nur mit Standardwert ergänzen – gespeicherte Vorlagen bleiben lesbar.
public struct ReportChapterOptions: Codable, Hashable, Sendable {
    // Einsatzdaten
    /// Kennzahlen (Sichtung, Patienten nach Stand) oben im Kapitel.
    public var showsSummary: Bool = true
    /// Kartenausschnitt (Vorschaubild oder letzter Kartenausschnitt).
    public var showsMapImage: Bool = true
    /// Verlauf: Meilensteine und Kennzahlen (Schritt 86).
    public var showsTimeline: Bool = true
    /// Nachbesprechung, falls vorhanden (Schritt 107).
    public var showsDebrief: Bool = true
    /// Deckblatt mit Titel, Kennzahlen, Lagekarte und SK-Verlauf (Schritt 137).
    public var showsCover: Bool = true

    // Organisation
    /// Platzhalter (Fahrzeug unbekannt) mit aufführen.
    public var includesPlaceholders: Bool = true
    /// Zugeordnete Patienten je Einheit nennen.
    public var showsPatientAssignment: Bool = true

    // Patienten (Schritt 42)
    /// Nur diese Sichtungskategorien (leer = alle).
    public var triageFilter: Set<Sichtungskategorie> = []
    /// Einzelbogen je Patient statt Tabelle.
    public var usesPatientSheets: Bool = false
    /// Namen im Bericht zeigen (Datenschutz: aus = nur Nummer, Alter, Geschlecht).
    public var showsPatientNames: Bool = true
    /// Nur Patienten für diese Zielklinik (Name; `nil` = alle). Für den Bericht an
    /// eine Klinik: sie erhält nur ihre Patienten (Schritt 56).
    public var destinationFilter: String?

    // Tagebuch und Protokoll (Schritt 43)
    /// Bilder im Tagebuch (Größe in Punkt; 0 = keine Bilder).
    public var journalImageHeight: Double = 220
    /// Protokoll nur dieser Bereiche (leer = alle).
    public var logCategories: Set<LogCategory> = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReportChapterOptions()
        showsSummary = try container.decodeIfPresent(Bool.self, forKey: .showsSummary) ?? defaults.showsSummary
        showsMapImage = try container.decodeIfPresent(Bool.self, forKey: .showsMapImage) ?? defaults.showsMapImage
        showsTimeline = try container.decodeIfPresent(Bool.self, forKey: .showsTimeline) ?? defaults.showsTimeline
        showsDebrief = try container.decodeIfPresent(Bool.self, forKey: .showsDebrief) ?? defaults.showsDebrief
        showsCover = try container.decodeIfPresent(Bool.self, forKey: .showsCover) ?? defaults.showsCover
        includesPlaceholders = try container.decodeIfPresent(Bool.self, forKey: .includesPlaceholders) ?? defaults.includesPlaceholders
        showsPatientAssignment = try container.decodeIfPresent(Bool.self, forKey: .showsPatientAssignment) ?? defaults.showsPatientAssignment
        triageFilter = try container.decodeIfPresent(Set<Sichtungskategorie>.self, forKey: .triageFilter) ?? defaults.triageFilter
        usesPatientSheets = try container.decodeIfPresent(Bool.self, forKey: .usesPatientSheets) ?? defaults.usesPatientSheets
        showsPatientNames = try container.decodeIfPresent(Bool.self, forKey: .showsPatientNames) ?? defaults.showsPatientNames
        destinationFilter = try container.decodeIfPresent(String.self, forKey: .destinationFilter)
        journalImageHeight = try container.decodeIfPresent(Double.self, forKey: .journalImageHeight) ?? defaults.journalImageHeight
        logCategories = try container.decodeIfPresent(Set<LogCategory>.self, forKey: .logCategories) ?? defaults.logCategories
    }
}

/// Alles, was ein Bericht braucht – als Werte, damit im Hintergrund gerendert
/// werden kann. Bilder kommen über `imageData` aus der Dateiablage.
public struct ReportInput: Sendable {
    public let mission: Mission
    public let patients: [Patient]
    public let units: [MissionUnit]
    public let sections: [MissionSection]
    public let journal: [JournalEntry]
    public let log: [MissionLogEntry]
    /// Namen der Benutzer (Einsatzleiter, Autoren).
    public let people: [UserID: String]
    public let createdAt: Date
    public let createdBy: String
    public let imageData: @Sendable (FileAttachment) -> Data?

    public init(
        mission: Mission,
        patients: [Patient],
        units: [MissionUnit],
        sections: [MissionSection],
        journal: [JournalEntry],
        log: [MissionLogEntry],
        people: [UserID: String] = [:],
        createdAt: Date = Date(),
        createdBy: String = "",
        imageData: @escaping @Sendable (FileAttachment) -> Data? = { _ in nil }
    ) {
        self.mission = mission
        self.patients = patients.active
        self.units = units.active
        self.sections = sections.active
        self.journal = journal.active
        self.log = log
        self.people = people
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.imageData = imageData
    }
}

// MARK: - Zielkliniken (Schritt 56)

/// Zielkliniken der Patienten eines Einsatzes, für die Auswahl „nur für Klinik …“.
public struct ReportDestination: Hashable, Sendable, Identifiable {
    public let name: String
    public let patientCount: Int
    public var id: String { name }

    /// Gleiche Klinik trotz anderer Schreibweise (Groß/klein, Leerzeichen).
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Gleiche Klinik (Schreibweise egal).
    public static func sameHospital(_ lhs: String, _ rhs: String) -> Bool {
        key(lhs) == key(rhs)
    }

    public static func matches(_ patient: Patient, filter: String) -> Bool {
        guard let name = patient.destination?.name else { return false }
        return key(name) == key(filter)
    }

    /// E-Mail-Adresse der Klinik aus den Zuweisungen (Schritt 62); `nil`, wenn keine
    /// hinterlegt ist. Bei mehreren Schreibweisen gilt die zuerst gefundene Adresse.
    public static func email(for filter: String, in patients: [Patient]) -> String? {
        patients
            .filter { !$0.isDeleted && matches($0, filter: filter) }
            .compactMap { $0.destination?.email.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.contains("@") }
    }

    /// Ersatz, wenn die Zuweisung keine Adresse trägt (z. B. Klinik von Hand
    /// eingetragen oder Stammdaten später ergänzt): Adresse aus den Stammdaten (Schritt 85).
    public static func email(for filter: String, in hospitals: [MasterHospital]) -> String? {
        hospitals
            .filter { key($0.name) == key(filter) }
            .map { $0.email.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.contains("@") }
    }

    /// Kliniken mit mindestens einem (nicht gelöschten) Patienten, meiste zuerst.
    public static func all(in patients: [Patient]) -> [ReportDestination] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for patient in patients where !patient.isDeleted {
            guard let name = patient.destination?.name, !key(name).isEmpty else { continue }
            let normalized = key(name)
            // Feste Wahl der Schreibweise, unabhängig von der Reihenfolge der Patienten.
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            names[normalized] = names[normalized].map { min($0, trimmed) } ?? trimmed
            counts[normalized, default: 0] += 1
        }
        return counts
            .map { ReportDestination(name: names[$0.key] ?? $0.key, patientCount: $0.value) }
            .sorted { ($0.patientCount, $1.name) > ($1.patientCount, $0.name) }
    }
}
