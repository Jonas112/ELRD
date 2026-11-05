import Foundation

/// Alle Stammdaten des Geräts als ein zusammenhängender Datenbestand.
///
/// Stammdaten ändern sich selten und werden als Ganzes gespeichert und (später)
/// mit dem ELRD-Backend abgeglichen. Daher keine Metadaten je Eintrag, sondern
/// eine `revision` für den ganzen Bestand (E35).
public struct MasterDataSet: Hashable, Codable, Sendable {
    public var units: [MasterUnit]
    public var hospitals: [MasterHospital]
    public var injuries: [MasterInjury]
    public var sections: [MasterSection]
    public var templates: [TextTemplate]
    /// IVENA-Katalog, der für RMI-Auswahl und PZC verwendet wird.
    public var ivenaCatalogID: String?
    /// Kennungen der bereits importierten Regionspakete.
    public var importedRegions: [String]
    /// Steigt bei jeder gespeicherten Änderung.
    public var revision: Int

    public init(
        units: [MasterUnit] = [],
        hospitals: [MasterHospital] = [],
        injuries: [MasterInjury] = [],
        sections: [MasterSection] = [],
        templates: [TextTemplate] = [],
        ivenaCatalogID: String? = nil,
        importedRegions: [String] = [],
        revision: Int = 0
    ) {
        self.units = units
        self.hospitals = hospitals
        self.injuries = injuries
        self.sections = sections
        self.templates = templates
        self.ivenaCatalogID = ivenaCatalogID
        self.importedRegions = importedRegions
        self.revision = revision
    }
}

/// Inhalt eines Imports (Regionspaket, CSV-Datei, später Backend).
public struct MasterDataPackage: Hashable, Sendable {
    public var regionID: String?
    public var units: [MasterUnit]
    public var hospitals: [MasterHospital]
    public var injuries: [MasterInjury]

    public init(regionID: String? = nil, units: [MasterUnit] = [], hospitals: [MasterHospital] = [], injuries: [MasterInjury] = []) {
        self.regionID = regionID
        self.units = units
        self.hospitals = hospitals
        self.injuries = injuries
    }
}

/// Ergebnis eines Imports zur Anzeige („42 Fahrzeuge übernommen, 3 bereits vorhanden“).
public struct MasterDataMergeReport: Hashable, Sendable {
    public var unitsAdded = 0
    public var unitsSkipped = 0
    public var unitsRemoved = 0
    public var hospitalsAdded = 0
    public var hospitalsSkipped = 0
    public var hospitalsRemoved = 0
    public var injuriesAdded = 0
    public var injuriesSkipped = 0

    public init() {}

    public var hasChanges: Bool {
        unitsAdded + unitsRemoved + hospitalsAdded + hospitalsRemoved + injuriesAdded > 0
    }
}

public extension MasterDataSet {
    enum MergeMode: Sendable {
        /// Nur fehlende Einträge ergänzen; vorhandene bleiben unverändert.
        case addMissing
        /// Zuvor aus derselben Region importierte Einträge ersetzen (Aktualisieren).
        /// Von Hand angelegte oder geänderte Herkunft bleibt erhalten.
        case replaceRegion
    }

    /// Übernimmt einen Import. Doppelte (gleicher Funkrufname bzw. Name + Ort)
    /// werden übersprungen.
    @discardableResult
    mutating func merge(_ package: MasterDataPackage, mode: MergeMode = .addMissing) -> MasterDataMergeReport {
        var report = MasterDataMergeReport()

        if mode == .replaceRegion, let regionID = package.regionID {
            let origin = MasterDataOrigin.region(regionID)
            let unitCount = units.count
            units.removeAll { $0.origin == origin }
            report.unitsRemoved = unitCount - units.count
            let hospitalCount = hospitals.count
            hospitals.removeAll { $0.origin == origin }
            report.hospitalsRemoved = hospitalCount - hospitals.count
        }

        var unitKeys = Set(units.map(\.matchKey))
        for unit in package.units where !unit.callsign.isEmpty {
            if unitKeys.insert(unit.matchKey).inserted {
                units.append(unit)
                report.unitsAdded += 1
            } else {
                report.unitsSkipped += 1
            }
        }

        var hospitalKeys = Set(hospitals.map(\.matchKey))
        for hospital in package.hospitals where !hospital.name.isEmpty {
            if hospitalKeys.insert(hospital.matchKey).inserted {
                hospitals.append(hospital)
                report.hospitalsAdded += 1
            } else {
                report.hospitalsSkipped += 1
            }
        }

        var injuryKeys = Set(injuries.map(\.matchKey))
        for injury in package.injuries where !injury.diagnosis.isEmpty {
            if injuryKeys.insert(injury.matchKey).inserted {
                injuries.append(injury)
                report.injuriesAdded += 1
            } else {
                report.injuriesSkipped += 1
            }
        }

        if let regionID = package.regionID, !importedRegions.contains(regionID) {
            importedRegions.append(regionID)
        }
        return report
    }

    /// Einheiten sortiert nach Typ und Funkrufname (natürliche Zahlensortierung).
    var sortedUnits: [MasterUnit] {
        units.sorted {
            if $0.type != $1.type { return $0.type.rawValue < $1.type.rawValue }
            return $0.callsign.localizedStandardCompare($1.callsign) == .orderedAscending
        }
    }

    var sortedHospitals: [MasterHospital] {
        hospitals.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Vorlagen, häufig benutzte zuerst.
    var sortedTemplates: [TextTemplate] {
        templates.sorted { ($0.useCount, $1.text) > ($1.useCount, $0.text) }
    }

    /// Abschnitte, die bei einem neuen Einsatz automatisch angelegt werden.
    var automaticSections: [MasterSection] {
        sections.filter(\.addAutomatically).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Übernimmt einen im Einsatz angelegten Abschnitt als Vorlage für künftige
    /// Einsätze (ELRDRG: „safe_new_sections_permanent“). Gibt es den Namen schon
    /// (Groß/klein und Leerraum egal), passiert nichts und es kommt `false`.
    @discardableResult
    mutating func addSection(named name: String) -> Bool {
        let candidate = MasterSection(name: name, sortIndex: (sections.map(\.sortIndex).max() ?? 0) + 1)
        guard !sections.contains(where: { $0.matchKey == candidate.matchKey }) else { return false }
        sections.append(candidate)
        revision += 1
        return true
    }

    /// Einheiten, die im Einsatz noch nicht verwendet werden (ELRDRG: „unused base units“).
    func unusedUnits(in missionUnits: some Sequence<MissionUnit>) -> [MasterUnit] {
        let used = Set(missionUnits.active.compactMap(\.masterUnitID))
        return sortedUnits.filter { !used.contains($0.id) }
    }
}
