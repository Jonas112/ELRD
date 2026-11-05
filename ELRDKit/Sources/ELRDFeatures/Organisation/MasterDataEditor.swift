import Foundation
import Observation
import ELRDDomain
import ELRDPersistence

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

    public init(repository: (any DocumentRepository)?) {
        self.repository = repository
        let master = repository.flatMap { try? $0.document(MasterDataSet.self, key: .masterData) }
        apply(master ?? MasterDataSet())
    }

    private func apply(_ master: MasterDataSet) {
        sections = master.sections.sorted { $0.sortIndex < $1.sortIndex }
        units = master.sortedUnits
    }

    private func change(at date: Date, _ edit: (inout MasterDataSet) -> Bool) throws {
        guard let repository else { return }
        var master = try repository.document(MasterDataSet.self, key: .masterData) ?? MasterDataSet()
        guard edit(&master) else { return }
        try repository.saveDocument(master, key: .masterData, at: date)
        apply(master)
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
}
