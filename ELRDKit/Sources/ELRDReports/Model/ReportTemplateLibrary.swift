import Foundation
import ELRDDomain

/// Vorlagen (Schritt 45): drei feste Standardvorlagen plus eigene. Standardvorlagen
/// lassen sich nicht ändern oder löschen – geänderte werden als Kopie gespeichert.
public struct ReportTemplateLibrary: Codable, Hashable, Sendable {
    /// Eigene Vorlagen.
    public private(set) var custom: [ReportTemplate]

    public init(custom: [ReportTemplate] = []) {
        self.custom = custom.filter { !Self.isStandard($0.id) }
    }

    // MARK: Standardvorlagen

    public static let fullID = UUID(uuidString: "E1D00000-0000-4000-8000-000000000001")!
    public static let shortID = UUID(uuidString: "E1D00000-0000-4000-8000-000000000002")!
    public static let hospitalID = UUID(uuidString: "E1D00000-0000-4000-8000-000000000003")!

    public static func isStandard(_ id: UUID) -> Bool { [fullID, shortID, hospitalID].contains(id) }

    /// Alles: Einsatzdaten, Organisation, Patienten, Tagebuch, Protokoll.
    public static var full: ReportTemplate {
        var template = ReportTemplate.full
        template.id = fullID
        template.name = "Gesamtbericht"
        return template
    }

    /// Für Leitstelle und Abschluss: Einsatzdaten, Organisation (ohne Platzhalter),
    /// Patiententabelle ohne Namen.
    public static var short: ReportTemplate {
        var organisation = ReportChapterOptions()
        organisation.includesPlaceholders = false
        var patients = ReportChapterOptions()
        patients.showsPatientNames = false
        return ReportTemplate(id: shortID, name: "Kurzbericht", chapters: [
            ReportChapter(kind: .missionInfo),
            ReportChapter(kind: .organisation, options: organisation),
            ReportChapter(kind: .patients, options: patients),
            ReportChapter(kind: .journal, isEnabled: false),
            ReportChapter(kind: .log, isEnabled: false),
        ])
    }

    /// Für die Übergabe an Kliniken: Einsatzdaten ohne Karte, Einzelbogen je Patient.
    public static var hospital: ReportTemplate {
        var info = ReportChapterOptions()
        info.showsSummary = false
        info.showsMapImage = false
        info.showsTimeline = false
        var patients = ReportChapterOptions()
        patients.usesPatientSheets = true
        return ReportTemplate(id: hospitalID, name: "Klinikbericht", chapters: [
            ReportChapter(kind: .missionInfo, options: info),
            ReportChapter(kind: .patients, options: patients),
            ReportChapter(kind: .organisation, isEnabled: false),
            ReportChapter(kind: .journal, isEnabled: false),
            ReportChapter(kind: .log, isEnabled: false),
        ])
    }

    public static var standardTemplates: [ReportTemplate] { [full, short, hospital] }

    // MARK: Zugriff

    /// Standardvorlagen zuerst, dann eigene alphabetisch.
    public var all: [ReportTemplate] {
        Self.standardTemplates + custom.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func template(id: UUID?) -> ReportTemplate? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Speichert eine eigene Vorlage (neu oder ersetzt gleiche Kennung). Eine
    /// Standardvorlage wird als Kopie mit neuer Kennung gespeichert. Leerer Name → „Eigene Vorlage“.
    @discardableResult
    public mutating func save(_ template: ReportTemplate) -> ReportTemplate {
        var stored = template
        if Self.isStandard(stored.id) { stored.id = UUID() }
        let trimmed = stored.name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.name = trimmed.isEmpty ? "Eigene Vorlage" : trimmed
        if let index = custom.firstIndex(where: { $0.id == stored.id }) {
            custom[index] = stored
        } else {
            custom.append(stored)
        }
        return stored
    }

    @discardableResult
    public mutating func delete(id: UUID) -> Bool {
        let before = custom.count
        custom.removeAll { $0.id == id }
        return custom.count != before
    }
}
