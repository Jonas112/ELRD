import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Tagebuch: Einträge ändern und löschen")
@MainActor
struct JournalCommandTests {
    @Test func manualEntryIsEditedAndDeleted() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let entry = try store.perform(AddJournalText("Erstmeldung abgegeben"))

        try store.perform(EditJournalEntry(entryID: entry.id, text: " Erstmeldung an ILS abgegeben "))
        #expect(store.state.journal.first { $0.id == entry.id }?.text == "Erstmeldung an ILS abgegeben")
        #expect(store.state.visibleLog.last?.message == "Tagebucheintrag \(entry.number) geändert (Text)")

        let earlier = entry.occurredAt.addingTimeInterval(-600)
        try store.perform(EditJournalEntry(entryID: entry.id, occurredAt: earlier))
        #expect(store.state.journal.first { $0.id == entry.id }?.occurredAt == earlier)
        #expect(store.state.visibleLog.last?.message == "Tagebucheintrag \(entry.number) geändert (Zeit)")

        let count = store.state.visibleLog.count
        try store.perform(EditJournalEntry(entryID: entry.id, text: "Erstmeldung an ILS abgegeben"))
        #expect(store.state.visibleLog.count == count, "unverändert")

        #expect(throws: CommandError.invalid("Ein Eintrag braucht Text. Zum Entfernen „Löschen“ wählen.")) {
            try store.perform(EditJournalEntry(entryID: entry.id, text: "   "))
        }

        try store.perform(DeleteJournalEntry(entryID: entry.id))
        #expect(JournalEntry.chronological(store.state.journal).allSatisfy { $0.id != entry.id })
        #expect(store.state.visibleLog.last?.message == "Tagebucheintrag \(entry.number) gelöscht")
        let next = try store.perform(AddJournalText("Lage unverändert"))
        #expect(next.number != entry.number, "Nummer bleibt vergeben")
    }

    @Test func automaticEntriesStayUntouched() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        try store.perform(CloseMission())
        let automatic = try #require(store.state.journal.first { $0.origin == .automatic })
        try store.perform(ReopenMission())
        #expect(throws: CommandError.invalid("Automatische Einträge lassen sich nicht ändern.")) {
            try store.perform(EditJournalEntry(entryID: automatic.id, text: "anders"))
        }
        #expect(throws: CommandError.invalid("Automatische Einträge lassen sich nicht löschen.")) {
            try store.perform(DeleteJournalEntry(entryID: automatic.id))
        }
    }
}

@Suite("Tagebuch: Textbausteine")
struct JournalTemplateTests {
    @Test func templatesAreUniqueAndSortedByUse() {
        var set = JournalTemplateSet()
        #expect(set.add("Lage unverändert"))
        #expect(!set.add("  lage UNVERÄNDERT "), "doppelt")
        #expect(!set.add("   "), "leer")
        #expect(set.add("Bereitstellungsraum eingerichtet"))
        #expect(set.sorted.map(\.text) == ["Bereitstellungsraum eingerichtet", "Lage unverändert"])
        let lage = set.templates[0]
        set.markUsed(id: lage.id)
        #expect(set.sorted.first?.text == "Lage unverändert", "meistgenutzt zuerst")
        set.remove(id: lage.id)
        #expect(set.templates.map(\.text) == ["Bereitstellungsraum eingerichtet"])
        #expect(JournalTemplateSet.defaults.templates.count >= 5)
    }
}
