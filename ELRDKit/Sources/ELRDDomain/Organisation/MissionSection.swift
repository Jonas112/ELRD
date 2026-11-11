import Foundation

/// Einsatzabschnitt (z. B. „Bereitstellungsraum“, „Patientenablage“).
public struct MissionSection: VersionedEntity, MissionScoped {
    public let id: SectionID
    public let missionID: MissionID
    public var metadata: EntityMetadata

    public var name: String
    /// Reihenfolge in Listen; neue Abschnitte werden hinten angefügt.
    public var sortIndex: Int
    /// Initialabschnitt: Hier landen neu hinzugefügte Einheiten.
    /// Pro Einsatz höchstens einer (siehe `MissionSection.applyingInitialRule`).
    public var isInitial: Bool
    /// Position auf der Lagekarte, falls gesetzt.
    public var coordinate: GeoCoordinate?
    /// Herkunft aus den Stammdaten, falls aus einer Vorlage angelegt.
    public var masterSectionID: MasterSectionID?

    /// Abschnittsleitung (Schritt 73).
    public var leaderName: String?
    public var leaderCallsign: String?
    public var radioChannel: String?
    /// Telefon/Mobil der Abschnittsleitung und Auftrag (DV 800, Schritt 126).
    public var leaderPhone: String?
    public var task: String?

    public init(
        id: SectionID = SectionID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        name: String,
        sortIndex: Int,
        isInitial: Bool = false,
        coordinate: GeoCoordinate? = nil,
        masterSectionID: MasterSectionID? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.name = MissionSection.normalizedName(name)
        self.sortIndex = sortIndex
        self.isInitial = isInitial
        self.coordinate = coordinate
        self.masterSectionID = masterSectionID
    }
}

// MARK: - Fachlogik

public extension MissionSection {
    static let fallbackName = "Neuer Abschnitt"

    /// Entfernt Leerraum; leere Namen werden durch `fallbackName` ersetzt.
    static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackName : trimmed
    }

    /// Nächster Sortierindex hinter allen vorhandenen Abschnitten des Einsatzes.
    static func nextSortIndex(existing sections: some Sequence<MissionSection>) -> Int {
        (sections.map(\.sortIndex).max() ?? 0) + 1
    }

    /// Der aktive Initialabschnitt eines Einsatzes, falls vorhanden.
    static func initialSection(in sections: some Sequence<MissionSection>) -> MissionSection? {
        sections.active.first(where: \.isInitial)
    }

    /// Setzt `sectionID` als einzigen Initialabschnitt und gibt alle Abschnitte zurück,
    /// deren Kennzeichen sich dadurch ändert (nur diese müssen gespeichert werden).
    /// Ist `sectionID` `nil`, wird kein Abschnitt mehr Initialabschnitt.
    static func applyingInitialRule(
        makeInitial sectionID: SectionID?,
        in sections: some Sequence<MissionSection>
    ) -> [MissionSection] {
        sections.active.compactMap { section in
            let shouldBeInitial = section.id == sectionID
            guard section.isInitial != shouldBeInitial else { return nil }
            var changed = section
            changed.isInitial = shouldBeInitial
            return changed
        }
    }

    /// Abschnitte in Anzeige-Reihenfolge (ohne gelöschte).
    static func sorted(_ sections: some Sequence<MissionSection>) -> [MissionSection] {
        sections.active.sorted {
            ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name)
        }
    }
}
