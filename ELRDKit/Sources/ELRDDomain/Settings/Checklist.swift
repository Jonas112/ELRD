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

// MARK: - Mehrere Checklisten und Einsatzarten (Schritt 78)

/// Benannte Checkliste (z. B. „MANV“, „Brand“).
public struct NamedChecklist: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var items: [ChecklistItem]

    public init(id: String = UUID().uuidString, name: String, items: [ChecklistItem]) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.items = items.filter { !$0.title.isEmpty }
    }

    public var template: ChecklistTemplate { ChecklistTemplate(items: items) }

    public static let standardID = "standard"
}

/// Einsatzart in den Einstellungen mit zugeordneter Checkliste.
public struct MissionTypeSetting: Hashable, Codable, Sendable, Identifiable {
    public var type: MissionType
    /// `nil` = Checkliste für Einsätze ohne eigene Zuordnung.
    public var checklistID: String?
    /// Vorlage (Schritt 106): Abschnitte, die zusätzlich zu den Stammdaten-Abschnitten
    /// angelegt werden, in dieser Reihenfolge.
    public var sectionNames: [String]?
    /// Initialabschnitt der Vorlage (Name aus `sectionNames` oder den Stammdaten).
    public var initialSectionName: String?
    /// Vorgeschlagenes Alarmstichwort (Rohwert, z. B. „RD 3“) – als Text gespeichert,
    /// damit ein unbekannter Wert die Einstellungen nicht unlesbar macht.
    public var alarmstichwortRaw: String?

    public init(type: MissionType, checklistID: String? = nil, sectionNames: [String]? = nil,
                initialSectionName: String? = nil, alarmstichwort: Alarmstichwort? = nil) {
        self.type = type
        self.checklistID = checklistID
        self.sectionNames = sectionNames
        self.initialSectionName = initialSectionName
        alarmstichwortRaw = alarmstichwort?.rawValue
    }

    public var id: String { type.rawValue }

    public var alarmstichwort: Alarmstichwort? {
        get { alarmstichwortRaw.flatMap(Alarmstichwort.init(rawValue:)) }
        set { alarmstichwortRaw = newValue?.rawValue }
    }

    /// Abschnitte der Vorlage ohne leere und doppelte Namen.
    public var templateSections: [String] {
        var seen = Set<String>()
        return (sectionNames ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Hat die Vorlage überhaupt Inhalt (außer der Checkliste)?
    public var hasTemplate: Bool { !templateSections.isEmpty || alarmstichwort != nil }
}

/// Abschnitte für einen neuen Einsatz: Stammdaten-Abschnitte plus die der Vorlage
/// (ohne Doppelte, Groß/klein egal). Initialabschnitt: Vorlage vor Stammdaten.
public enum MissionTemplateSections {
    public static func merge(master: [String], masterInitial: String?, template: MissionTypeSetting?) -> (names: [String], initial: String?) {
        var names = master
        var seen = Set(master.map { $0.lowercased() })
        for name in template?.templateSections ?? [] where seen.insert(name.lowercased()).inserted {
            names.append(name)
        }
        let wanted = template?.initialSectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = wanted.flatMap { wanted in names.first { $0.caseInsensitiveCompare(wanted) == .orderedSame } } ?? masterInitial
        return (names, initial)
    }
}

public extension MissionType {
    /// Reihenfolge der mitgelieferten Arten (häufige zuerst).
    static let defaultOrder: [MissionType] = [
        .verkehrsunfall, .brand, .bma, .mehrfachErkrankte, .gefahrgut,
        .vermisstensuche, .polizeiSonderlage, .bergrettung, .wasserrettung, .sonstiges,
    ]
}

