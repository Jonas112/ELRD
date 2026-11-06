import Foundation

/// Textbaustein für das Tagebuch (ELRDRG `DocumentationTemplate`): häufig
/// gebrauchte Einträge mit einem Tipp. Sortiert nach Nutzung wie in ELRDRG.
public struct JournalTemplate: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var text: String
    public var useCount: Int

    public init(id: UUID = UUID(), text: String, useCount: Int = 0) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.useCount = max(useCount, 0)
    }
}

/// Alle Textbausteine des Geräts (ein Dokument wie die Stammdaten).
public struct JournalTemplateSet: Hashable, Codable, Sendable {
    public private(set) var templates: [JournalTemplate]

    public init(templates: [JournalTemplate] = []) {
        self.templates = []
        for template in templates { _ = add(template.text, useCount: template.useCount, id: template.id) }
    }

    /// Startbausteine für neue Geräte – fachlich üblich, jederzeit löschbar.
    public static let defaults = JournalTemplateSet(templates: [
        "Erstmeldung an ILS abgegeben",
        "Lagemeldung an ILS abgegeben",
        "Nachalarmierung angefordert",
        "Bereitstellungsraum eingerichtet",
        "Patientenablage eingerichtet",
        "Lage unverändert",
        "Einsatzstelle an Feuerwehr übergeben",
        "Letzter Patient abtransportiert",
    ].map { JournalTemplate(text: $0) })

    /// Meistgenutzte zuerst, dann alphabetisch.
    public var sorted: [JournalTemplate] {
        templates.sorted { lhs, rhs in
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
        }
    }

    public func contains(_ text: String) -> Bool {
        let key = MasterDataMatching.key(text)
        return templates.contains { MasterDataMatching.key($0.text) == key }
    }

    /// Fügt einen Baustein hinzu; leere und doppelte (Groß/klein egal) werden ignoriert.
    @discardableResult
    public mutating func add(_ text: String, useCount: Int = 0, id: UUID = UUID()) -> Bool {
        let template = JournalTemplate(id: id, text: text, useCount: useCount)
        guard !template.text.isEmpty, !contains(template.text) else { return false }
        templates.append(template)
        return true
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        let before = templates.count
        templates.removeAll { $0.id == id }
        return templates.count != before
    }

    /// Zählt eine Verwendung (bestimmt die Reihenfolge).
    @discardableResult
    public mutating func markUsed(id: UUID) -> Bool {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return false }
        templates[index].useCount += 1
        return true
    }
}
