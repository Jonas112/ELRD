import Foundation
import ELRDDomain

// MARK: - Tagebuch

/// Speichert einen Ausschnitt der Lagekarte als Tagebucheintrag (ELRDRG: Karte
/// „ins Tagebuch“). Das Bild liegt bereits in der Dateiablage.
public struct AddMapSnapshot: MissionCommand {
    public let image: FileAttachment
    public let note: String

    public init(image: FileAttachment, note: String = "") {
        self.image = image
        self.note = note
    }

    public func execute(_ draft: inout MissionDraft) throws -> JournalEntry {
        guard image.kind == .photo else { throw CommandError.invalid("Ein Kartenausschnitt muss ein Bild sein.") }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = try draft.addJournalEntry(
            text: trimmed.isEmpty ? "Lagekarte" : "Lagekarte: \(trimmed)",
            origin: .mapSnapshot,
            attachments: [image]
        )
        draft.log(.journal, "Kartenausschnitt als Tagebucheintrag \(entry.number) gespeichert", subject: .journalEntry(entry.id))
        return entry
    }
}

/// Liest einen aktiven Tagebucheintrag oder meldet „nicht gefunden“.
@MainActor
private func activeJournalEntry(_ id: JournalEntryID, in draft: MissionDraft) throws -> JournalEntry {
    guard let entry = draft.get(JournalEntry.self, id: id), !entry.metadata.isDeleted else {
        throw CommandError.notFound(.journalEntry)
    }
    return entry
}

/// Ändert Text oder Zeitpunkt eines Eintrags (`nil`: unverändert). Automatische
/// Einträge der App (z. B. „Einsatz beendet“) bleiben unverändert.
public struct EditJournalEntry: MissionCommand {
    public let entryID: JournalEntryID
    public let text: String?
    public let occurredAt: Date?

    public init(entryID: JournalEntryID, text: String? = nil, occurredAt: Date? = nil) {
        self.entryID = entryID
        self.text = text
        self.occurredAt = occurredAt
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let before = try activeJournalEntry(entryID, in: draft)
        guard before.origin != .automatic else {
            throw CommandError.invalid("Automatische Einträge lassen sich nicht ändern.")
        }
        let newText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? before.text
        let newDate = occurredAt ?? before.occurredAt
        guard newText != before.text || newDate != before.occurredAt else { return }
        if newText.isEmpty, before.attachments.isEmpty {
            throw CommandError.invalid("Ein Eintrag braucht Text. Zum Entfernen „Löschen“ wählen.")
        }
        try draft.update(JournalEntry.self, id: entryID) { entry in
            entry.text = newText
            entry.occurredAt = newDate
        }
        let what = newText != before.text && newDate != before.occurredAt ? "Text und Zeit"
            : newText != before.text ? "Text" : "Zeit"
        draft.log(.journal, "Tagebucheintrag \(before.number) geändert (\(what))", subject: .journalEntry(entryID))
    }
}

/// Löscht einen Eintrag (weich, die Nummer bleibt vergeben). Automatische Einträge
/// bleiben erhalten.
public struct DeleteJournalEntry: MissionCommand {
    public let entryID: JournalEntryID

    public init(entryID: JournalEntryID) {
        self.entryID = entryID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let entry = try activeJournalEntry(entryID, in: draft)
        guard entry.origin != .automatic else {
            throw CommandError.invalid("Automatische Einträge lassen sich nicht löschen.")
        }
        try draft.delete(JournalEntry.self, id: entryID)
        draft.log(.journal, "Tagebucheintrag \(entry.number) gelöscht", subject: .journalEntry(entryID))
    }
}
