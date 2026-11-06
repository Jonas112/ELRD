import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDFeatures

@Suite("Tagebuch: Textbausteine speichern")
@MainActor
struct JournalTemplateEditorTests {
    @Test func defaultsAppearAndChangesAreStored() throws {
        let repository = InMemoryRepository()
        let editor = JournalTemplateEditor(repository: repository)
        #expect(editor.templates.count == JournalTemplateSet.defaults.templates.count, "Startbausteine")

        try editor.add("RTH gelandet")
        #expect(editor.contains("rth gelandet"))
        let stored = try #require(try repository.document(JournalTemplateSet.self, key: .journalTemplates))
        #expect(stored.contains("RTH gelandet"))

        let template = try #require(editor.templates.first { $0.text == "RTH gelandet" })
        editor.markUsed(template)
        #expect(editor.templates.first?.text == "RTH gelandet", "nach Nutzung vorne")

        try editor.remove(template)
        #expect(!JournalTemplateEditor(repository: repository).contains("RTH gelandet"), "bleibt gelöscht")
    }
}
