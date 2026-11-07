import Foundation
import Observation
import ELRDDomain
import ELRDPersistence
import ELRDStammdaten

/// Stammdaten für den Einsatz: Abschnitts-Vorlagen und Einheiten. Neue Abschnitte
/// und temporäre Einheiten lassen sich für künftige Einsätze übernehmen.
///
/// Liest und schreibt nur das Stammdaten-Dokument, nie Einsatzdaten – die laufen
/// immer über `MissionStore`.
@MainActor
@Observable
public final class MasterDataEditor {
    private let repository: (any DocumentRepository)?
    public private(set) var sections: [MasterSection] = []
    public private(set) var units: [MasterUnit] = []
    /// Kliniken alphabetisch (Schritt 48).
    public private(set) var hospitals: [MasterHospital] = []
    /// Gewählter IVENA-Katalog (Schritt 49).
    public private(set) var ivenaCatalogID: String?
    /// Steigt bei jeder Änderung – z. B. um Klinikauswahl neu zu laden.
    public private(set) var revision = 0
    /// Mitgelieferte Regionen, die schon geladen wurden.
    public private(set) var loadedRegionIDs: Set<String> = []

    public init(repository: (any DocumentRepository)?) {
        self.repository = repository
        let master = repository.flatMap { try? $0.document(MasterDataSet.self, key: .masterData) }
        apply(master ?? MasterDataSet())
    }

    private func apply(_ master: MasterDataSet) {
        sections = master.sections.sorted { $0.sortIndex < $1.sortIndex }
        units = master.sortedUnits
        hospitals = master.hospitals.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        ivenaCatalogID = master.ivenaCatalogID
        loadedRegionIDs = Set(master.units.compactMap(\.origin.regionID) + master.hospitals.compactMap(\.origin.regionID))
    }

    // MARK: Regionen

    /// Lädt ein mitgeliefertes Regionspaket (Fahrzeuge, Kliniken) in die Stammdaten.
    /// Vorhandene Einträge bleiben, doppelte werden übersprungen.
    @discardableResult
    func importRegion(_ region: RegionDefinition, at date: Date = Date()) throws -> MasterDataMergeReport {
        guard let repository else { return MasterDataMergeReport() }
        let loaded = try BundledMasterData.package(for: region)
        var master = try repository.document(MasterDataSet.self, key: .masterData) ?? MasterDataSet()
        let report = master.merge(loaded.package)
        try repository.saveDocument(master, key: .masterData, at: date)
        apply(master)
        revision += 1
        return report
    }

    private func change(at date: Date, _ edit: (inout MasterDataSet) -> Bool) throws {
        guard let repository else { return }
        var master = try repository.document(MasterDataSet.self, key: .masterData) ?? MasterDataSet()
        guard edit(&master) else { return }
        try repository.saveDocument(master, key: .masterData, at: date)
        apply(master)
        revision += 1
    }

    // MARK: Abschnitte

    /// Vorlagen, die im Einsatz noch nicht als Abschnitt vorkommen.
    func unused(in missionSections: [MissionSection]) -> [MasterSection] {
        let used = Set(missionSections.active.map { MasterDataMatching.key($0.name) })
        return sections.filter { !used.contains($0.matchKey) }
    }

    /// Ob es den Namen schon als Vorlage gibt.
    func contains(_ name: String) -> Bool {
        let key = MasterDataMatching.key(MissionSection.normalizedName(name))
        return sections.contains { $0.matchKey == key }
    }

    /// Übernimmt einen Abschnittsnamen in die Stammdaten (doppelte werden ignoriert).
    func save(_ name: String, at date: Date = Date()) throws {
        try change(at: date) { $0.addSection(named: name) }
    }

    // MARK: Einheiten

    /// Stammdaten-Einheiten, die im Einsatz noch nicht eingesetzt sind.
    func unusedUnits(in missionUnits: [MissionUnit]) -> [MasterUnit] {
        let used = Set(missionUnits.active.compactMap(\.masterUnitID))
        return units.filter { !used.contains($0.id) }
    }

    /// Ob es den Funkrufnamen schon in den Stammdaten gibt.
    func containsUnit(_ callsign: String) -> Bool {
        let key = MasterDataMatching.key(callsign)
        return units.contains { $0.matchKey == key }
    }

    /// Übernimmt eine temporäre Einheit in die Stammdaten (doppelte werden ignoriert).
    func saveUnit(callsign: String, type: UnitType, at date: Date = Date()) throws {
        try change(at: date) { $0.addUnit(callsign: callsign, type: type) != nil }
    }

    // MARK: Verwaltung (Schritt 48)

    /// Neue oder geänderte Einheit. Ein schon vorhandener Funkrufname (andere Kennung)
    /// wird abgelehnt.
    func upsertUnit(_ unit: MasterUnit, at date: Date = Date()) throws {
        let callsign = unit.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callsign.isEmpty else { throw MasterDataEditError.emptyName }
        let key = MasterDataMatching.key(callsign)
        guard !units.contains(where: { $0.matchKey == key && $0.id != unit.id }) else { throw MasterDataEditError.duplicate(callsign) }
        var cleaned = unit
        cleaned.callsign = callsign
        try change(at: date) { master in
            if let index = master.units.firstIndex(where: { $0.id == cleaned.id }) {
                master.units[index] = cleaned
            } else {
                master.units.append(cleaned)
            }
            master.revision += 1
            return true
        }
    }

    func removeUnit(_ id: MasterUnitID, at date: Date = Date()) throws {
        try change(at: date) { master in
            let before = master.units.count
            master.units.removeAll { $0.id == id }
            master.revision += 1
            return master.units.count != before
        }
    }

    func upsertHospital(_ hospital: MasterHospital, at date: Date = Date()) throws {
        let name = hospital.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MasterDataEditError.emptyName }
        let key = MasterDataMatching.key(name)
        guard !hospitals.contains(where: { MasterDataMatching.key($0.name) == key && $0.id != hospital.id }) else {
            throw MasterDataEditError.duplicate(name)
        }
        var cleaned = hospital
        cleaned.name = name
        try change(at: date) { master in
            if let index = master.hospitals.firstIndex(where: { $0.id == cleaned.id }) {
                master.hospitals[index] = cleaned
            } else {
                master.hospitals.append(cleaned)
            }
            master.revision += 1
            return true
        }
    }

    func removeHospital(_ id: MasterHospitalID, at date: Date = Date()) throws {
        try change(at: date) { master in
            let before = master.hospitals.count
            master.hospitals.removeAll { $0.id == id }
            master.revision += 1
            return master.hospitals.count != before
        }
    }

    func removeSection(_ id: MasterSectionID, at date: Date = Date()) throws {
        try change(at: date) { master in
            let before = master.sections.count
            master.sections.removeAll { $0.id == id }
            master.revision += 1
            return master.sections.count != before
        }
    }

    /// Initialabschnitt für neue Einsätze (höchstens einer; `nil`: keiner).
    func setInitialSection(_ id: MasterSectionID?, at date: Date = Date()) throws {
        try change(at: date) { master in
            for index in master.sections.indices {
                master.sections[index].isInitial = master.sections[index].id == id
            }
            master.revision += 1
            return true
        }
    }

    /// Wählt den IVENA-Katalog (Schritt 49).
    func setIVENACatalog(_ id: String, at date: Date = Date()) throws {
        guard id != ivenaCatalogID else { return }
        try change(at: date) { master in
            master.ivenaCatalogID = id
            master.revision += 1
            return true
        }
    }
}

enum MasterDataEditError: LocalizedError, Equatable {
    case emptyName
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Bitte einen Namen eingeben."
        case .duplicate(let name): "„\(name)“ gibt es schon."
        }
    }
}
