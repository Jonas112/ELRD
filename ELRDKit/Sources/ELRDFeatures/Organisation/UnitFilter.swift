import Foundation
import ELRDDomain

/// Typfilter der Einheiten: die häufigen Rettungsmittel einzeln, der Rest gesammelt.
enum UnitTypeFilter: Hashable, CaseIterable, Identifiable {
    case all, rtw, ktw, nef, rth, other

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Alle"
        case .rtw: "RTW"
        case .ktw: "KTW"
        case .nef: "NEF"
        case .rth: "RTH"
        case .other: "Sonstige"
        }
    }

    func matches(_ type: UnitType) -> Bool {
        switch self {
        case .all: true
        case .rtw: type == .rtw
        case .ktw: type == .ktw || type == .ktwKatS
        case .nef: type == .nef
        case .rth: type == .rth
        case .other: ![.rtw, .ktw, .ktwKatS, .nef, .rth].contains(type)
        }
    }
}

/// Filter und Suche für Einheiten (im Einsatz und in den Stammdaten).
struct UnitFilter: Equatable {
    var type: UnitTypeFilter = .all
    var search = ""

    var isActive: Bool { type != .all || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Alle Suchwörter müssen im Namen oder Typ vorkommen (Groß/klein und Akzente egal).
    func matches(type unitType: UnitType, text: String) -> Bool {
        guard type.matches(unitType) else { return false }
        let words = search.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func matches(_ unit: MissionUnit) -> Bool {
        matches(type: unit.type, text: "\(unit.displayName) \(unit.typeDisplayName)")
    }

    func matches(_ unit: MasterUnit) -> Bool {
        matches(type: unit.type, text: "\(unit.callsign) \(unit.typeDisplayName)")
    }

    /// Anzahl je Typfilter (mit der aktuellen Suche), für die Filter-Kapseln.
    static func counts<Item>(
        _ items: [Item],
        search: String,
        type typeOf: (Item) -> UnitType,
        text textOf: (Item) -> String
    ) -> [UnitTypeFilter: Int] {
        var result: [UnitTypeFilter: Int] = [:]
        for candidate in UnitTypeFilter.allCases {
            let probe = UnitFilter(type: candidate, search: search)
            result[candidate] = items.filter { probe.matches(type: typeOf($0), text: textOf($0)) }.count
        }
        return result
    }
}

extension SectionColumn {
    /// Spalte mit nur den passenden Einheiten; `nil`, wenn bei aktivem Filter nichts passt.
    func filtered(by filter: UnitFilter) -> SectionColumn? {
        guard filter.isActive else { return self }
        let matching = units.filter { filter.matches($0.unit) }
        guard !matching.isEmpty else { return nil }
        return SectionColumn(section: section, units: matching, loosePatients: [])
    }
}
