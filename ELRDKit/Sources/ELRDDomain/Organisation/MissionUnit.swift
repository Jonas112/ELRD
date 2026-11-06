import Foundation

/// Einheit im Einsatz (Fahrzeug, Hubschrauber, Gruppe) oder Platzhalter dafür.
///
/// Platzhalter entstehen z. B. durch Alarmstichworte, solange noch nicht bekannt
/// ist, welches konkrete Fahrzeug kommt. Sie werden später durch eine echte Einheit
/// ersetzt – die Kennung bleibt dabei gleich, damit Zuordnungen erhalten bleiben.
public struct MissionUnit: VersionedEntity, MissionScoped {
    public let id: UnitID
    public let missionID: MissionID
    public var metadata: EntityMetadata

    public var type: UnitType
    /// Ursprüngliche Typbezeichnung aus den Stammdaten (z. B. „HVO“), falls genauer als `type` (E38).
    public var typeLabel: String?
    /// Funkrufname. Bei Platzhaltern `nil`.
    public private(set) var callsign: String?
    /// Besatzungsstärke, falls bekannt.
    public var crewCount: Int?
    /// Laufende Nummer, solange die Einheit ein Platzhalter ist.
    public private(set) var placeholderNumber: Int?
    /// Herkunft aus den Stammdaten. `nil` bei Platzhaltern und temporär angelegten Einheiten.
    public private(set) var masterUnitID: MasterUnitID?
    /// Abschnitt, in dem die Einheit eingesetzt ist.
    public var sectionID: SectionID?

    /// Legt eine reale Einheit an (aus Stammdaten oder temporär).
    public init(
        id: UnitID = UnitID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        type: UnitType,
        typeLabel: String? = nil,
        callsign: String,
        crewCount: Int? = nil,
        masterUnitID: MasterUnitID? = nil,
        sectionID: SectionID? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.type = type
        self.typeLabel = typeLabel
        self.callsign = MissionUnit.normalizedCallsign(callsign)
        self.crewCount = MissionUnit.normalizedCrewCount(crewCount)
        self.placeholderNumber = nil
        self.masterUnitID = masterUnitID
        self.sectionID = sectionID
    }

    /// Legt einen Platzhalter an.
    public init(
        id: UnitID = UnitID(),
        missionID: MissionID,
        metadata: EntityMetadata,
        placeholderType type: UnitType,
        number: Int,
        sectionID: SectionID? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.metadata = metadata
        self.type = type
        self.callsign = nil
        self.crewCount = nil
        self.placeholderNumber = max(number, 1)
        self.masterUnitID = nil
        self.sectionID = sectionID
    }
}

// MARK: - Fachlogik

public extension MissionUnit {
    var isPlaceholder: Bool { placeholderNumber != nil }

    /// Temporär angelegt: weder Platzhalter noch aus den Stammdaten.
    var isTemporary: Bool { !isPlaceholder && masterUnitID == nil }

    /// Typ zur Anzeige: Originalbezeichnung („HVO“), sonst Kurzname („RTW“).
    var typeDisplayName: String { typeLabel ?? type.shortName }

    /// Reale Einheit aus einem Stammdaten-Eintrag.
    static func from(
        _ master: MasterUnit,
        missionID: MissionID,
        metadata: EntityMetadata,
        sectionID: SectionID?
    ) -> MissionUnit {
        MissionUnit(
            missionID: missionID,
            metadata: metadata,
            type: master.type,
            typeLabel: master.typeLabel,
            callsign: master.callsign,
            crewCount: master.crewCount,
            masterUnitID: master.id,
            sectionID: sectionID
        )
    }

    /// Schlüssel zum Erkennen doppelter Funkrufnamen (wie in den Stammdaten).
    var matchKey: String? { callsign.map(MasterDataMatching.key) }

    /// Anzeigename, z. B. „Rotkreuz Musterstadt 71/1“ oder „RTW (Platzhalter 3)“.
    var displayName: String {
        if let placeholderNumber {
            return "\(type.shortName) (Platzhalter \(placeholderNumber))"
        }
        return callsign ?? type.shortName
    }

    /// Ändert den Funkrufnamen einer realen Einheit. Bei Platzhaltern ohne Wirkung –
    /// diese werden über `replacePlaceholder` zu einer realen Einheit.
    mutating func rename(to callsign: String) {
        guard !isPlaceholder else { return }
        self.callsign = MissionUnit.normalizedCallsign(callsign)
    }

    /// Ersetzt einen Platzhalter durch eine reale Einheit. Kennung, Einsatz und
    /// Abschnitt bleiben erhalten. Gibt `false` zurück, wenn kein Platzhalter vorlag.
    @discardableResult
    mutating func replacePlaceholder(
        callsign: String,
        type: UnitType,
        typeLabel: String? = nil,
        crewCount: Int?,
        masterUnitID: MasterUnitID?
    ) -> Bool {
        guard isPlaceholder else { return false }
        self.placeholderNumber = nil
        self.callsign = MissionUnit.normalizedCallsign(callsign)
        self.type = type
        self.typeLabel = typeLabel
        self.crewCount = MissionUnit.normalizedCrewCount(crewCount)
        self.masterUnitID = masterUnitID
        return true
    }

    /// Nächste Platzhalter-Nummer im Einsatz (über alle Typen, wie in ELRDRG).
    /// Gelöschte und bereits ersetzte Platzhalter zählen nicht mehr.
    static func nextPlaceholderNumber(existing units: some Sequence<MissionUnit>) -> Int {
        (units.active.compactMap(\.placeholderNumber).max() ?? 0) + 1
    }

    /// Erzeugt die Platzhalter für ein Alarmstichwort (z. B. RD 3 → 2 RTW, 1 NEF)
    /// mit fortlaufenden Nummern im Anschluss an die vorhandenen Platzhalter.
    static func placeholders(
        for stichwort: Alarmstichwort,
        missionID: MissionID,
        sectionID: SectionID?,
        existing units: some Sequence<MissionUnit>,
        author: UserID?,
        at date: Date
    ) -> [MissionUnit] {
        let firstNumber = nextPlaceholderNumber(existing: units)
        return stichwort.unitsToCreate.enumerated().map { offset, type in
            MissionUnit(
                missionID: missionID,
                metadata: .new(by: author, at: date),
                placeholderType: type,
                number: firstNumber + offset,
                sectionID: sectionID
            )
        }
    }

    static func normalizedCallsign(_ callsign: String) -> String? {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedCrewCount(_ crewCount: Int?) -> Int? {
        guard let crewCount, crewCount > 0 else { return nil }
        return crewCount
    }

    /// Einheiten in Anzeige-Reihenfolge: reale vor Platzhaltern, dann nach Typ und Name.
    static func sorted(_ units: some Sequence<MissionUnit>) -> [MissionUnit] {
        units.active.sorted { lhs, rhs in
            if lhs.isPlaceholder != rhs.isPlaceholder { return !lhs.isPlaceholder }
            if lhs.type != rhs.type { return lhs.type.rawValue < rhs.type.rawValue }
            if let l = lhs.placeholderNumber, let r = rhs.placeholderNumber { return l < r }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}
