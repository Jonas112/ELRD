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
        let first = set.add("Lage unverändert")
        let duplicate = set.add("  lage UNVERÄNDERT ")
        let empty = set.add("   ")
        let second = set.add("Bereitstellungsraum eingerichtet")
        #expect(first)
        #expect(!duplicate, "doppelt")
        #expect(!empty, "leer")
        #expect(second)
        #expect(set.sorted.map(\.text) == ["Bereitstellungsraum eingerichtet", "Lage unverändert"])
        let lage = set.templates[0]
        set.markUsed(id: lage.id)
        #expect(set.sorted.first?.text == "Lage unverändert", "meistgenutzt zuerst")
        set.remove(id: lage.id)
        #expect(set.templates.map(\.text) == ["Bereitstellungsraum eingerichtet"])
        #expect(JournalTemplateSet.defaults.templates.count >= 5)
    }
}

@Suite("Tagebuch: Fotos, Sprachnotizen, Vorschaubild")
@MainActor
struct JournalMediaCommandTests {
    func file(_ kind: AttachmentKind, _ digit: Character, duration: TimeInterval? = nil) -> FileAttachment {
        FileAttachment(kind: kind, byteCount: 10, sha256: String(repeating: digit, count: 64), createdAt: Date(), duration: duration)
    }

    @Test func photosAndVoiceNotesBecomeEntries() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let photos = try store.perform(AddJournalMedia(attachments: [file(.photo, "a"), file(.photo, "b")], text: " Unfallstelle von Norden "))
        #expect(photos.kind == .photo)
        #expect(photos.text == "Unfallstelle von Norden")
        #expect(store.state.visibleLog.last?.message == "Fotoeintrag (2 Fotos) \(photos.number) erfasst")

        let voice = try store.perform(AddJournalMedia(attachments: [file(.audio, "c", duration: 42)]))
        #expect(voice.kind == .audio)
        #expect(voice.text.isEmpty)
        #expect(store.state.visibleLog.last?.message == "Sprachnotiz \(voice.number) erfasst")

        #expect(throws: CommandError.invalid("Kein Foto und keine Aufnahme ausgewählt.")) {
            try store.perform(AddJournalMedia(attachments: []))
        }
        #expect(throws: CommandError.invalid("Zeichnungen gehören auf die Karte.")) {
            try store.perform(AddJournalMedia(attachments: [file(.drawing, "d")]))
        }
        // Ein Fotoeintrag ohne Text bleibt gültig.
        try store.perform(EditJournalEntry(entryID: photos.id, text: ""))
        #expect(store.state.journal.first { $0.id == photos.id }?.text == "")
    }

    @Test func onlyOneEntryIsMissionThumbnail() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let first = try store.perform(AddJournalMedia(attachments: [file(.photo, "a")]))
        let second = try store.perform(AddJournalMedia(attachments: [file(.photo, "b")]))
        let text = try store.perform(AddJournalText("ohne Bild"))
        try store.perform(SetMissionThumbnail(entryID: second.id))
        #expect(store.state.journal.filter(\.isMissionThumbnail).map(\.id) == [second.id])
        #expect(JournalEntry.thumbnail(in: store.state.journal) == second.firstImage)
        try store.perform(SetMissionThumbnail(entryID: first.id))
        #expect(store.state.journal.filter(\.isMissionThumbnail).map(\.id) == [first.id])
        #expect(throws: CommandError.invalid("Dieser Eintrag hat kein Bild.")) {
            try store.perform(SetMissionThumbnail(entryID: text.id))
        }
        try store.perform(SetMissionThumbnail(entryID: nil))
        #expect(store.state.journal.allSatisfy { !$0.isMissionThumbnail })
        #expect(store.state.visibleLog.last?.message == "Vorschaubild des Einsatzes: automatisch")
    }
}
