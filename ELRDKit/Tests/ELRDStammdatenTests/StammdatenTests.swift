import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDStammdaten

@Suite("CSV-Leser")
struct CSVParserTests {
    @Test func semicolonsBomAndLineEndings() {
        let rows = CSVParser.parse("\u{FEFF}Funkrufname;Typ;\r\nR AB 71/1;RTW;\r\n\r\nR AB 71/2 ; KTW\n")
        #expect(rows.map(\.fields) == [["Funkrufname", "Typ"], ["R AB 71/1", "RTW"], ["R AB 71/2", "KTW"]])
        #expect(rows.map(\.line) == [1, 2, 4])
    }

    @Test func commaDelimiterAndQuotes() {
        let rows = CSVParser.parse("Name,Ort\n\"Klinik \"\"Nord\"\", Haus 2\",Musterstadt\n\"Zeile\nmit Umbruch\",X")
        #expect(rows.count == 3)
        #expect(rows[1].fields == ["Klinik \"Nord\", Haus 2", "Musterstadt"])
        #expect(rows[2].fields == ["Zeile\nmit Umbruch", "X"])
        #expect(rows[2][5] == nil)
    }

    @Test func latin1Fallback() throws {
        let data = try #require("Stadt;Straße\nBad Kötzting;Hauptstraße 1".data(using: .isoLatin1))
        let rows = try CSVParser.parse(data: data)
        #expect(rows.last?.fields == ["Bad Kötzting", "Hauptstraße 1"])
    }
}

@Suite("Fahrzeugtypen")
struct UnitTypeMappingTests {
    @Test(arguments: [
        ("RTW", UnitType.rtw), ("S-RTW", .rtw), ("NAW", .rtw), ("KTW", .ktw), ("KTW 4", .ktw), ("KTW B", .ktw),
        ("NEF", .nef), ("VEF", .nef), ("RTH", .rth), ("RTH/POL", .rth),
        ("KDOW", .kdow), ("Kdow", .kdow), ("ELRD", .kdow), ("OrgL", .kdow), ("LNA", .kdow),
        ("ELW", .elw), ("UGSanEL", .elw), ("MTW", .mtw), ("MZF", .mtw), ("Krad", .krad),
        ("LKW", .lkw), ("LKW Verpflegung", .lkw), ("Kat-KTW", .ktwKatS),
        ("Wasserwacht", .wasserwacht), ("WRW", .wasserwacht), ("MRB II", .wasserwacht), ("Boot", .wasserwacht),
        ("HVO", .sonstiges), ("GW Hund", .sonstiges), ("", .sonstiges),
    ])
    func mapping(label: String, expected: UnitType) {
        #expect(UnitTypeMapping.unitType(for: label) == expected)
    }

    @Test func originalLabelIsKeptOnlyWhenMoreSpecific() {
        #expect(MasterUnit(callsign: "X", type: .sonstiges, typeLabel: "HVO").typeDisplayName == "HVO")
        #expect(MasterUnit(callsign: "X", type: .rtw, typeLabel: "RTW").typeLabel == nil)
        #expect(MasterUnit(callsign: "X", type: .kdow, typeLabel: "KDOW").typeLabel == nil)
    }
}

@Suite("CSV-Import")
struct MasterDataImporterTests {
    @Test func unitsWithoutHeaderKeepFirstRow() {
        // ELRDRG übersprang hier die erste Zeile und verlor ein Fahrzeug.
        let result = MasterDataImporter.units(fromCSV: "Rotkreuz Coburg 71/1;RTW\nRotkreuz Coburg 76/1;NEF", origin: .manual)
        #expect(result.items.map(\.callsign) == ["Rotkreuz Coburg 71/1", "Rotkreuz Coburg 76/1"])
        #expect(result.items.map(\.type) == [.rtw, .nef])
    }

    @Test func hospitalColumnsByHeaderNotPosition() throws {
        // Aschaffenburg: Stadt steht vor der Straße – ELRDRG hat das vertauscht.
        let csv = "Anzeigename;Stadt;Straße + Hausnummer;Latitude;Longitude;Telefonnummer;E-Mail Adresse\nKlinik A;Musterstadt;Hauptstr. 1;49,97;9.18;0123;a@b.de"
        let result = MasterDataImporter.hospitals(fromCSV: csv, origin: .manual)
        let hospital = try #require(result.items.first)
        #expect(hospital.city == "Musterstadt")
        #expect(hospital.address == "Hauptstr. 1")
        #expect(hospital.coordinate == GeoCoordinate(latitude: 49.97, longitude: 9.18))
        #expect(hospital.snapshot.displayName == "Klinik A / Musterstadt")
    }

    @Test func invalidRowsAreReportedNotFatal() {
        let csv = "Anzeigename;Straße + Hausnummer;Stadt;Latitude;Longitude\n;Weg 1;Ort;;\nKlinik B;Weg 2;Ort;95;10"
        let result = MasterDataImporter.hospitals(fromCSV: csv, origin: .manual)
        #expect(result.items.map(\.name) == ["Klinik B"])
        #expect(result.items.first?.coordinate == nil)
        #expect(result.issues.map(\.line) == [2, 3])
    }

    @Test func registrationEmailColumn() {
        let csv = "Anzeigename;E-Mail Adresse;E-Mail Adresse Anmeldung\nKlinik C;info@c.de;anmeldung@c.de"
        let hospital = MasterDataImporter.hospitals(fromCSV: csv, origin: .manual).items.first
        #expect(hospital?.email == "info@c.de")
        #expect(hospital?.snapshot.email == "anmeldung@c.de")
    }
}

@Suite("Mitgelieferte Stammdaten")
struct BundledMasterDataTests {
    @Test(arguments: [
        ("rhoen-grabfeld", 144, 60), ("schweinfurt", 42, 60), ("aschaffenburg", 176, 15),
        ("coburg", 37, 49), ("dachau", 134, 31), ("kempten", 59, 0), ("unterfranken-kliniken", 0, 60),
    ])
    func regionPackagesLoadCompletely(regionID: String, units: Int, hospitals: Int) throws {
        let region = try #require(BundledMasterData.region(id: regionID))
        let (package, issues) = try BundledMasterData.package(for: region)
        #expect(package.units.count == units)
        #expect(package.hospitals.count == hospitals)
        #expect(issues.isEmpty, "\(issues)")
        let allFromRegion = package.units.allSatisfy { $0.origin == .region(regionID) }
        #expect(allFromRegion)
    }

    @Test func aschaffenburgHospitalsHaveCorrectCity() throws {
        let region = try #require(BundledMasterData.region(id: "aschaffenburg"))
        let campus = try BundledMasterData.package(for: region).package.hospitals.first { $0.name == "Campus Rhön" }
        #expect(campus?.city == "Bad Neustadt")
        #expect(campus?.address == "Am Campus 1")
    }

    @Test func rhoenGrabfeldTripledListIsDeduplicated() throws {
        let region = try #require(BundledMasterData.region(id: "rhoen-grabfeld"))
        var set = MasterDataSet()
        let report = set.merge(try BundledMasterData.package(for: region).package)
        #expect(report.unitsAdded == 48)
        #expect(report.unitsSkipped == 96)
        #expect(set.importedRegions == ["rhoen-grabfeld"])
    }

    @Test func diagnosesAreCorrected() throws {
        let diagnoses = try BundledMasterData.diagnoses()
        #expect(diagnoses.count == 59)
        let names = Set(diagnoses.map(\.diagnosis))
        #expect(names.isSuperset(of: ["Unterschenkel#", "Unterschenkel# offen", "Commotio"]))
        let noGlued = !names.contains("Unterschenkel#Unterschenkel# offen")
        #expect(noGlued)
        let allHaveRegion = diagnoses.allSatisfy { $0.region != nil }
        #expect(allHaveRegion)
    }

    @Test func ivenaCatalogs() throws {
        let bayern = try #require(try BundledMasterData.ivenaCatalog(id: "ivena-bayern"))
        #expect(bayern.entries.count == 187)
        #expect(bayern.categories.first == "Reanimation")
        #expect(bayern.entries.contains { $0.category == "Verletzungen/Unfälle - Mehrfach" })

        let untermain = try #require(try BundledMasterData.ivenaCatalog(id: "ivena-untermain"))
        #expect(untermain.entries.count == 189)
        let face = try #require(untermain.entry(code: 749))
        #expect(face.title == "Mund - Kiefer - Gesicht - Notfall, sonstiger")
        #expect(face.category == "74x Mund - Kiefer - Gesicht")
        #expect(face.triageHint == "SK 2+3")
        #expect(untermain.entry(code: 273)?.title == "Hüft - / Schenkelhalsfraktur")
        #expect(untermain.search("reanimation").count >= 4)
        #expect(untermain.search("21").allSatisfy { String($0.code).hasPrefix("21") || $0.title.contains("21") || $0.category.contains("21") })
    }

    @Test func initialMasterData() throws {
        let set = try BundledMasterData.initialMasterData()
        #expect(set.injuries.count == 59)
        #expect(set.ivenaCatalogID == "ivena-bayern")
        #expect(set.units.isEmpty)
    }
}

@Suite("Stammdaten zusammenführen")
struct MasterDataMergeTests {
    @Test func addMissingSkipsDuplicatesCaseInsensitive() {
        var set = MasterDataSet(units: [MasterUnit(callsign: "RK AB 71/1", type: .rtw)])
        let report = set.merge(MasterDataPackage(units: [
            MasterUnit(callsign: "rk  ab 71/1", type: .ktw),
            MasterUnit(callsign: "RK AB 76/1", type: .nef),
        ]))
        #expect(report.unitsAdded == 1)
        #expect(report.unitsSkipped == 1)
        #expect(set.units.first?.type == .rtw, "Vorhandener Eintrag bleibt unverändert")
    }

    @Test func replaceRegionKeepsManualEntries() {
        var set = MasterDataSet()
        set.merge(MasterDataPackage(regionID: "coburg", units: [
            MasterUnit(callsign: "Alt 1", type: .rtw, origin: .region("coburg")),
        ]))
        set.units.append(MasterUnit(callsign: "Eigenes Fahrzeug", type: .kdow, origin: .manual))

        let report = set.merge(MasterDataPackage(regionID: "coburg", units: [
            MasterUnit(callsign: "Neu 1", type: .rtw, origin: .region("coburg")),
        ]), mode: .replaceRegion)

        #expect(report.unitsRemoved == 1)
        #expect(Set(set.units.map(\.callsign)) == ["Eigenes Fahrzeug", "Neu 1"])
        #expect(set.importedRegions == ["coburg"])
    }

    @Test func unusedUnitsAndMissionUnit() {
        let rtw = MasterUnit(callsign: "RTW 1", type: .rtw, crewCount: 2)
        let nef = MasterUnit(callsign: "NEF 1", type: .nef)
        let set = MasterDataSet(units: [rtw, nef])
        let missionID = MissionID()
        let unit = rtw.makeMissionUnit(missionID: missionID, metadata: .new(by: nil, at: Date()), sectionID: nil)
        #expect(unit.masterUnitID == rtw.id)
        #expect(unit.crewCount == 2)
        #expect(set.unusedUnits(in: [unit]).map(\.callsign) == ["NEF 1"])
    }

    @Test func sortingAndTemplates() {
        let set = MasterDataSet(
            units: [MasterUnit(callsign: "RTW 10", type: .rtw), MasterUnit(callsign: "NEF 1", type: .nef), MasterUnit(callsign: "RTW 2", type: .rtw)],
            sections: [
                MasterSection(name: "B", sortIndex: 2, addAutomatically: true),
                MasterSection(name: "A", sortIndex: 1, addAutomatically: true, isInitial: true),
                MasterSection(name: "C", sortIndex: 3),
            ],
            templates: [TextTemplate(text: "Selten", useCount: 1), TextTemplate(text: "Oft", useCount: 9), TextTemplate(text: "Auch oft", useCount: 9)]
        )
        #expect(set.sortedUnits.map(\.callsign) == ["RTW 2", "RTW 10", "NEF 1"])
        #expect(set.automaticSections.map(\.name) == ["A", "B"])
        #expect(set.sortedTemplates.map(\.text) == ["Auch oft", "Oft", "Selten"])
    }

    @Test func roundTripsThroughJSON() throws {
        var set = try BundledMasterData.initialMasterData()
        set.hospitals.append(MasterHospital(name: "Klinik", coordinate: GeoCoordinate(latitude: 50, longitude: 10), origin: .region("x")))
        let decoded = try JSONDecoder().decode(MasterDataSet.self, from: JSONEncoder().encode(set))
        #expect(decoded == set)
    }
}
