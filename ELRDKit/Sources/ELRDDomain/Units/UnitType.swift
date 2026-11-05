/// Typ einer Einsatzeinheit (Fahrzeug, Luftrettungsmittel, Gruppe).
///
/// Rohwerte entsprechen ELRDRG (`Unit.type`, `BaseUnit.type`) und dem
/// ELRD-Backend und dürfen nicht geändert werden.
public enum UnitType: Int, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case rtw = 0
    case ktw = 1
    case nef = 2
    case rth = 3
    case sonstiges = 4
    case krad = 5
    case kdow = 6
    case mtw = 7
    case lkw = 8
    case ktwKatS = 9
    case wasserwacht = 10
    case elw = 11

    public var id: Int { rawValue }

    public var shortName: String {
        switch self {
        case .rtw: "RTW"
        case .ktw: "KTW"
        case .nef: "NEF"
        case .rth: "RTH"
        case .sonstiges: "Sonst."
        case .krad: "Krad"
        case .kdow: "KdoW"
        case .mtw: "MTW"
        case .lkw: "LKW"
        case .ktwKatS: "KTW-KatS"
        case .wasserwacht: "WW"
        case .elw: "ELW"
        }
    }

    public var displayName: String {
        switch self {
        case .rtw: "Rettungswagen"
        case .ktw: "Krankentransportwagen"
        case .nef: "Notarzteinsatzfahrzeug"
        case .rth: "Rettungshubschrauber"
        case .sonstiges: "Sonstiges"
        case .krad: "Kraftrad"
        case .kdow: "Kommandowagen"
        case .mtw: "Mannschaftstransportwagen"
        case .lkw: "Lastkraftwagen"
        case .ktwKatS: "KTW Katastrophenschutz"
        case .wasserwacht: "Wasserwacht"
        case .elw: "Einsatzleitwagen"
        }
    }

    /// Darf Patienten transportieren (Jonas, E66). NEF, HvO usw. können einem
    /// Patienten zugeordnet werden, reichen aber nicht für „Transport starten“.
    public var transportsPatients: Bool {
        switch self {
        case .rtw, .ktw, .rth, .ktwKatS: true
        default: false
        }
    }

    /// Typen, für die es eine Schnellanlage als Platzhalter gibt (wie in ELRDRG).
    public static let placeholderQuickAddTypes: [UnitType] = [.rtw, .ktw, .nef]
}
