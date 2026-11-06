import Foundation
import Observation
import ELRDDomain
import ELRDPersistence

/// Textbausteine des Tagebuchs (Gerätedokument, nicht Teil des Einsatzes).
/// Beim ersten Gebrauch werden die Startbausteine angelegt.
@MainActor
@Observable
public final class JournalTemplateEditor {
    private let repository: (any DocumentRepository)?
    public private(set) var templates: [JournalTemplate] = []

    public init(repository: (any DocumentRepository)?) {
        self.repository = repository
        let stored = repository.flatMap { try? $0.document(JournalTemplateSet.self, key: .journalTemplates) }
        templates = (stored ?? .defaults).sorted
    }

    func contains(_ text: String) -> Bool {
        JournalTemplateSet(templates: templates).contains(text)
    }

    func add(_ text: String, at date: Date = Date()) throws {
        try change(at: date) { $0.add(text) }
    }

    func remove(_ template: JournalTemplate, at date: Date = Date()) throws {
        try change(at: date) { $0.remove(id: template.id) }
    }

    /// Verwendung zählen; Fehler beim Speichern sind hier unkritisch.
    func markUsed(_ template: JournalTemplate, at date: Date = Date()) {
        try? change(at: date) { $0.markUsed(id: template.id) }
    }

    private func change(at date: Date, _ edit: (inout JournalTemplateSet) -> Bool) throws {
        let stored = repository.flatMap { try? $0.document(JournalTemplateSet.self, key: .journalTemplates) }
        var working = stored ?? JournalTemplateSet(templates: templates)
        guard edit(&working) else { return }
        try repository?.saveDocument(working, key: .journalTemplates, at: date)
        templates = working.sorted
    }
}
