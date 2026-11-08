import Foundation

// MARK: - Checkliste (Schritt 76)

/// Punkt der Einsatz-Checkliste. Die Kennung bleibt beim Umbenennen gleich.
public struct ChecklistItem: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String = UUID().uuidString, title: String) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Vorlage der Checkliste (in den Einstellungen, `AppSettings.checklist`).
public struct ChecklistTemplate: Hashable, Codable, Sendable {
    public var items: [ChecklistItem]

    public init(items: [ChecklistItem]) {
        self.items = items.filter { !$0.title.isEmpty }
    }

    /// Erste Maßnahmen der Einsatzleitung RD beim MANV (anpassbar in den Einstellungen).
    public static let standard = ChecklistTemplate(items: [
        ChecklistItem(id: "lage", title: "Lage erkundet, erste Rückmeldung an ILS"),
        ChecklistItem(id: "abschnitte", title: "Abschnitte festgelegt (Patientenablage, Bereitstellungsraum)"),
        ChecklistItem(id: "anfahrt", title: "Anfahrtsweg und Bereitstellungsraum an ILS gemeldet"),
        ChecklistItem(id: "fuehrung", title: "LNA und OrgL eingebunden"),
        ChecklistItem(id: "funk", title: "Funkkanäle festgelegt"),
        ChecklistItem(id: "gefahren", title: "Gefahren geklärt, Absprache mit Feuerwehr und Polizei"),
        ChecklistItem(id: "sichtung", title: "Sichtung begonnen"),
        ChecklistItem(id: "ablage", title: "Patientenablage eingerichtet"),
        ChecklistItem(id: "kliniken", title: "Kliniken informiert, Kontingente abgefragt"),
        ChecklistItem(id: "nachforderung", title: "Nachforderung geprüft"),
        ChecklistItem(id: "betreuung", title: "Betreuung Unverletzter / PSNV organisiert"),
        ChecklistItem(id: "lagemeldung", title: "Lagemeldungen im Takt an ILS"),
    ])

    /// Aus Text (eine Zeile je Punkt). Unveränderte Titel behalten ihre Kennung,
    /// damit Abgehaktes erhalten bleibt.
    public func updated(fromLines text: String) -> ChecklistTemplate {
        var remaining = items
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let result = lines.map { line -> ChecklistItem in
            if let index = remaining.firstIndex(where: { $0.title == line }) {
                return remaining.remove(at: index)
            }
            return ChecklistItem(title: line)
        }
        return ChecklistTemplate(items: result)
    }

    public var lines: String { items.map(\.title).joined(separator: "\n") }
}

