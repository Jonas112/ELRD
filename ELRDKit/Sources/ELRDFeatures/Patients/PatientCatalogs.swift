import Foundation
import ELRDDomain
import ELRDPersistence
import ELRDStammdaten

/// Kataloge für die Patientenerfassung: Diagnosen, IVENA (RMI), Kliniken.
///
/// Einmal je Anmeldung aus den Stammdaten geladen und an den Arbeitsbereich gereicht.
public struct PatientCatalogs: Sendable {
    public var injuries: [MasterInjury]
    public var rmi: RMICatalog?
    public var hospitals: [MasterHospital]

    public init(injuries: [MasterInjury] = [], rmi: RMICatalog? = nil, hospitals: [MasterHospital] = []) {
        self.injuries = injuries
        self.rmi = rmi
        self.hospitals = hospitals
    }

    public static let empty = PatientCatalogs()

    /// Aus den gespeicherten Stammdaten; IVENA-Katalog aus der App (Bayern als Vorgabe).
    @MainActor
    static func load(from repository: any DocumentRepository) -> PatientCatalogs {
        let master = (try? repository.document(MasterDataSet.self, key: .masterData)) ?? MasterDataSet()
        let catalogID = master.ivenaCatalogID ?? BundledMasterData.ivenaCatalogs.first?.id
        let rmi = catalogID.flatMap { try? BundledMasterData.ivenaCatalog(id: $0) }
        return PatientCatalogs(injuries: master.injuries, rmi: rmi, hospitals: master.sortedHospitals)
    }
}

/// Auswahl im Verletzungs-Dialog (ohne Oberfläche testbar).
enum InjurySuggestions {
    /// Regionen in der Reihenfolge der Auswahl: von Kopf bis Fuß.
    static let regionOrder: [BodyRegion] = [.kopf, .wirbelsaeule, .thorax, .abdomen, .arm, .hand, .oberschenkel, .unterschenkel]

    /// Passende Diagnosen: zur Region (falls gewählt) und zu allen Suchwörtern.
    static func matches(in catalog: [MasterInjury], region: BodyRegion?, search: String) -> [MasterInjury] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return catalog
            .filter { region == nil || $0.region == region }
            .filter { injury in
                words.allSatisfy { injury.diagnosis.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            .sorted {
                let left = (regionOrder.firstIndex(of: $0.region ?? .kopf) ?? 99, $0.diagnosis.lowercased())
                let right = (regionOrder.firstIndex(of: $1.region ?? .kopf) ?? 99, $1.diagnosis.lowercased())
                return left < right
            }
    }

    /// Ob „neue Diagnose“ angeboten wird: Text vorhanden und nicht genau im Katalog.
    static func offersCustom(_ search: String, in matches: [MasterInjury]) -> Bool {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return !matches.contains { $0.diagnosis.caseInsensitiveCompare(text) == .orderedSame }
    }

    /// Verletzung aus Katalogeintrag bzw. Freitext.
    static func injury(from master: MasterInjury?, text: String, region: BodyRegion?, side: BodySide?) -> Injury {
        Injury(
            diagnosis: master?.diagnosis ?? text,
            region: master?.region ?? region,
            side: side,
            masterInjuryID: master?.id
        )
    }
}
