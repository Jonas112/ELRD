/// Alarmstichwort für den Rettungsdienst.
///
/// Ein Stichwort legt fest, welche Platzhalter-Einheiten beim Hinzufügen
/// erzeugt werden. Werte wie in ELRDRG (`UnitHandler.getAlarmstichwortDetails`).
public enum Alarmstichwort: String, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case rd1 = "RD 1"
    case rd2 = "RD 2"
    case rd3 = "RD 3"
    case rd4 = "RD 4"
    case rd5 = "RD 5"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    /// Anzahl der Einheiten je Typ, die das Stichwort auslöst.
    public var requiredUnits: [UnitType: Int] {
        switch self {
        case .rd1: [.rtw: 1]
        case .rd2: [.rtw: 1, .nef: 1]
        case .rd3: [.rtw: 2, .nef: 1]
        case .rd4: [.rtw: 4, .nef: 2]
        case .rd5: [.rtw: 5, .nef: 3]
        }
    }

    /// Alle zu erzeugenden Einheitentypen als flache, stabil sortierte Liste
    /// (z. B. RD 3 → [RTW, RTW, NEF]).
    public var unitsToCreate: [UnitType] {
        requiredUnits
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { type, count in Array(repeating: type, count: count) }
    }

    /// Kurzbeschreibung, z. B. „2 RTW, 1 NEF“.
    public var summary: String {
        requiredUnits
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.shortName)" }
            .joined(separator: ", ")
    }
}
