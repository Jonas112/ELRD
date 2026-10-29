import ELRDDomain

/// Ordnet Typbezeichnungen aus Fahrzeuglisten einem `UnitType` zu.
///
/// ELRDRG kannte nur sieben Bezeichnungen und legte alles andere als „Sonstiges“
/// an. Hier werden alle Bezeichnungen aus den Regionslisten zugeordnet; die
/// Originalbezeichnung bleibt in `MasterUnit.typeLabel` erhalten.
public enum UnitTypeMapping {
    public static func unitType(for label: String) -> UnitType {
        let key = normalize(label)
        if let exact = table[key] { return exact }
        // Varianten wie „KTW 4“, „KTW B“, „LKW Verpflegung“, „GW San 25“.
        for (prefix, type) in prefixes where key.hasPrefix(prefix) { return type }
        return .sonstiges
    }

    static func normalize(_ label: String) -> String {
        label.uppercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let table: [String: UnitType] = [
        "RTW": .rtw, "S RTW": .rtw, "NAW": .rtw, "ITW": .rtw,
        "KTW": .ktw,
        "NEF": .nef, "VEF": .nef,
        "RTH": .rth, "RTH/POL": .rth, "ITH": .rth,
        "KDOW": .kdow, "ELRD": .kdow, "ORGL": .kdow, "LNA": .kdow,
        "K BEAUFTRAGTER": .kdow, "STELL. K BEAUFTRAGTER": .kdow, "KBL": .kdow,
        "ELW": .elw, "UGSANEL": .elw, "LAGEZENTRUM": .elw,
        "MTW": .mtw, "MZF": .mtw,
        "KRAD": .krad,
        "LKW": .lkw,
        "KAT KTW": .ktwKatS, "KTW KATS": .ktwKatS,
        "WASSERWACHT": .wasserwacht, "WRW": .wasserwacht, "BOOT": .wasserwacht,
        "SONSTIGES": .sonstiges, "SONST": .sonstiges,
    ]

    private static let prefixes: [(String, UnitType)] = [
        ("KTW ", .ktw),
        ("LKW ", .lkw),
        ("MRB", .wasserwacht),
    ]
}
