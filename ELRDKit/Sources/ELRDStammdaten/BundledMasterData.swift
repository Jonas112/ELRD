import Foundation
import ELRDDomain

/// ELRDStammdaten – Stammdaten-Import.
///
/// Mitgelieferte Regionspakete (Fahrzeuge, Kliniken), Diagnosekatalog und
/// IVENA-Kataloge sowie der CSV-Import für eigene Listen.
public enum ELRDStammdatenModule {
    public static let name = "ELRDStammdaten"
}

/// Ein mitgeliefertes Regionspaket.
public struct RegionDefinition: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    let unitsFile: String?
    let hospitalsFile: String?

    public var hasUnits: Bool { unitsFile != nil }
    public var hasHospitals: Bool { hospitalsFile != nil }
}

/// Zugriff auf die mit der App ausgelieferten Stammdaten.
public enum BundledMasterData {
    /// Regionen wie in ELRDRG. Regionen ohne eigene Klinikliste nutzen dort die
    /// Liste „Unterfranken“ (ELRDRG: „Kliniken-Allgemein“); sie wird hier als
    /// eigenes Paket angeboten, statt sie stillschweigend mitzuladen.
    public static let regions: [RegionDefinition] = [
        RegionDefinition(id: "rhoen-grabfeld", name: "Rhön-Grabfeld", unitsFile: "Fahrzeuge-Rhoen-Grabfeld", hospitalsFile: "Kliniken-Unterfranken"),
        RegionDefinition(id: "schweinfurt", name: "Schweinfurt", unitsFile: "Fahrzeuge-Schweinfurt", hospitalsFile: "Kliniken-Unterfranken"),
        RegionDefinition(id: "aschaffenburg", name: "Aschaffenburg", unitsFile: "Fahrzeuge-Aschaffenburg", hospitalsFile: "Kliniken-Aschaffenburg"),
        RegionDefinition(id: "coburg", name: "Coburg", unitsFile: "Fahrzeuge-Coburg", hospitalsFile: "Kliniken-Coburg"),
        RegionDefinition(id: "dachau", name: "Dachau", unitsFile: "Fahrzeuge-Dachau", hospitalsFile: "Kliniken-Dachau"),
        RegionDefinition(id: "kempten", name: "Kempten", unitsFile: "Fahrzeuge-Kempten", hospitalsFile: nil),
        RegionDefinition(id: "unterfranken-kliniken", name: "Kliniken Unterfranken", unitsFile: nil, hospitalsFile: "Kliniken-Unterfranken"),
    ]

    public static func region(id: String) -> RegionDefinition? {
        regions.first { $0.id == id }
    }

    /// Lädt ein Regionspaket. Hinweise zu nicht übernommenen Zeilen stehen in `issues`.
    public static func package(for region: RegionDefinition) throws -> (package: MasterDataPackage, issues: [ImportIssue]) {
        let origin = MasterDataOrigin.region(region.id)
        var package = MasterDataPackage(regionID: region.id)
        var issues: [ImportIssue] = []
        if let file = region.unitsFile {
            let result = MasterDataImporter.units(fromCSV: try text(path: "Regionen/\(file).csv"), origin: origin)
            package.units = result.items
            issues += result.issues
        }
        if let file = region.hospitalsFile {
            let result = MasterDataImporter.hospitals(fromCSV: try text(path: "Regionen/\(file).csv"), origin: origin)
            package.hospitals = result.items
            issues += result.issues
        }
        return (package, issues)
    }

    /// Mitgelieferter Diagnosekatalog (aus ELRDRG, korrigiert).
    public static func diagnoses() throws -> [MasterInjury] {
        MasterDataImporter.injuries(fromCSV: try text(path: "Diagnosen.csv"), origin: .manual).items
    }

    /// Verfügbare IVENA-Kataloge.
    public static let ivenaCatalogs: [(id: String, name: String, file: String)] = [
        ("ivena-bayern", "IVENA Bayern", "IVENA-Bayern"),
        ("ivena-untermain", "IVENA Untermain", "IVENA-Untermain"),
    ]

    public static func ivenaCatalog(id: String) throws -> RMICatalog? {
        guard let info = ivenaCatalogs.first(where: { $0.id == id }) else { return nil }
        let entries = IVENACatalogParser.parse(try text(path: "IVENA/\(info.file).txt")).items
        return RMICatalog(id: info.id, name: info.name, entries: entries)
    }

    /// Ausgangsbestand für ein neues Gerät: Diagnosekatalog und IVENA Bayern.
    public static func initialMasterData() throws -> MasterDataSet {
        var set = MasterDataSet(ivenaCatalogID: "ivena-bayern")
        set.merge(MasterDataPackage(injuries: try diagnoses()))
        return set
    }

    static func text(path: String) throws -> String {
        // Ordner heißt bewusst nicht „Resources“: Ein solcher Ordner in einem iOS-Bundle
        // bringt die Code-Signatur durcheinander.
        guard let base = Bundle.module.resourceURL?.appendingPathComponent("Daten", isDirectory: true) else {
            throw BundledDataError.missingResource(path)
        }
        let url = base.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw BundledDataError.missingResource(path)
        }
        return text
    }
}

public enum BundledDataError: Error, Equatable, Sendable {
    case missingResource(String)
}

extension BundledDataError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): "Die mitgelieferten Daten „\(name)“ fehlen. Bitte die App neu installieren."
        }
    }
}
