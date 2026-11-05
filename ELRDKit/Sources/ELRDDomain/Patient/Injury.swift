import Foundation

/// Verletzung bzw. Diagnose eines Patienten.
///
/// Wird im Patienten gespeichert (nicht als eigene Tabelle). Jede Verletzung hat
/// eine eigene Kennung, damit spätere Synchronisation Einträge einzeln
/// hinzufügen und entfernen kann, statt die ganze Liste zu überschreiben.
public struct Injury: Identifiable, Hashable, Codable, Sendable {
    public let id: InjuryID
    public var diagnosis: String
    public var region: BodyRegion?
    /// Nur sinnvoll, wenn `region?.hasSide == true`.
    public private(set) var side: BodySide?
    /// Herkunft aus den Stammdaten (Diagnosekatalog), falls ausgewählt.
    public var masterInjuryID: MasterInjuryID?

    public init(
        id: InjuryID = InjuryID(),
        diagnosis: String,
        region: BodyRegion? = nil,
        side: BodySide? = nil,
        masterInjuryID: MasterInjuryID? = nil
    ) {
        self.id = id
        self.diagnosis = diagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        self.side = region?.hasSide == true ? side : nil
        self.masterInjuryID = masterInjuryID
    }

    /// Setzt Region und Seite gemeinsam; eine Seite ohne passende Region wird verworfen.
    public mutating func setLocation(region: BodyRegion?, side: BodySide?) {
        self.region = region
        self.side = region?.hasSide == true ? side : nil
    }

    /// Ortsangabe, z. B. „Unterschenkel rechts“ oder „Thorax“.
    public var locationText: String {
        [region?.displayName, side?.displayName].compactMap { $0 }.joined(separator: " ")
    }

    /// Anzeige wie in ELRDRG: „Diagnose Ort“, z. B. „Fraktur Unterschenkel rechts“.
    /// Steckt die Region schon in der Diagnose („Unterschenkel#“, „stumpfes
    /// Thoraxtrauma“), wird sie nicht wiederholt: „Unterschenkel# rechts“.
    public var displayText: String {
        let regionInDiagnosis = region.map { diagnosis.range(of: $0.displayName, options: .caseInsensitive) != nil } ?? false
        let location = regionInDiagnosis ? (side?.displayName ?? "") : locationText
        return [diagnosis, location].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
