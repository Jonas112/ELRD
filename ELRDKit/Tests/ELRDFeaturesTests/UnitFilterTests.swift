import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDFeatures
import ELRDStore

@Suite("Einheiten filtern")
@MainActor
struct UnitFilterTests {
    @Test func typeFilterGroupsRareTypes() {
        #expect(UnitTypeFilter.ktw.matches(.ktwKatS))
        #expect(UnitTypeFilter.other.matches(.elw))
        #expect(UnitTypeFilter.other.matches(.sonstiges))
        #expect(!UnitTypeFilter.other.matches(.nef))
        let filtersPerType = UnitType.allCases.map { type in
            UnitTypeFilter.allCases.filter { $0 != .all && $0.matches(type) }.count
        }
        #expect(filtersPerType == Array(repeating: 1, count: UnitType.allCases.count), "jeder Typ genau einem Filter")
    }

    @Test func searchAndCounts() {
        let units = [
            MasterUnit(callsign: "RK SWFT 71/1", type: .rtw),
            MasterUnit(callsign: "RK SWFT 76/1", type: .nef),
            MasterUnit(callsign: "JOH SWFT 71/1", type: .rtw),
            MasterUnit(callsign: "HvO Gochsheim", type: .sonstiges, typeLabel: "HVO"),
        ]
        let filter = UnitFilter(type: .rtw, search: "swft 71")
        #expect(units.filter { filter.matches($0) }.map(\.callsign) == ["RK SWFT 71/1", "JOH SWFT 71/1"])
        #expect(UnitFilter(search: "hvo").isActive)
        #expect(units.filter { UnitFilter(search: "hvo").matches($0) }.count == 1, "Typbezeichnung durchsuchbar")
        let counts = UnitFilter.counts(units, search: "swft", type: \.type) { $0.callsign }
        #expect(counts[.all] == 3 && counts[.rtw] == 2 && counts[.nef] == 1 && counts[.other] == 0)
    }

    @Test func filteredColumnsHideEmptySections() throws {
        let store = try PreviewData.makeStore() // RD 3 im Bereitstellungsraum
        let columns = SectionColumn.columns(for: store.state)
        let nefOnly = columns.compactMap { $0.filtered(by: UnitFilter(type: .nef)) }
        #expect(nefOnly.map(\.title) == ["Bereitstellungsraum"])
        #expect(nefOnly.first?.units.count == 1)
        #expect(columns.compactMap { $0.filtered(by: UnitFilter()) }.count == columns.count, "ohne Filter alles")
    }

    @Test func editorOffersOnlyUnusedUnitsAndSavesTemporary() throws {
        let repository = InMemoryRepository()
        let rtw = MasterUnit(callsign: "RK SWFT 71/1", type: .rtw)
        try repository.saveDocument(MasterDataSet(units: [rtw]), key: .masterData, at: Date())
        let editor = MasterDataEditor(repository: repository)
        let store = try PreviewData.makeStore()
        #expect(editor.unusedUnits(in: store.state.units).map(\.callsign) == ["RK SWFT 71/1"])
        _ = try store.perform(AddMasterUnits([rtw]))
        #expect(editor.unusedUnits(in: store.state.units).isEmpty)

        try editor.saveUnit(callsign: "Florian Musterstadt 1", type: .elw)
        #expect(editor.containsUnit("florian musterstadt 1"))
        #expect(try repository.document(MasterDataSet.self, key: .masterData)?.units.count == 2)
    }

    @Test func placeholderTypePicksNarrowestFilter() {
        #expect(UnitTypeFilter.matching(.rtw) == .rtw)
        #expect(UnitTypeFilter.matching(.ktwKatS) == .ktw)
        #expect(UnitTypeFilter.matching(.elw) == .other)
    }
}
