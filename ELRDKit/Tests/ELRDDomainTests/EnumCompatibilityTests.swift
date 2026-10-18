import Foundation
import Testing
@testable import ELRDDomain

/// Die Rohwerte sind ein Vertrag mit ELRDRG-Daten und dem ELRD-Backend.
/// Schlägt ein Test hier fehl, wurde ein Code versehentlich geändert.
@Suite("Rohwerte kompatibel zu ELRDRG / ELRD-Backend")
struct EnumCompatibilityTests {
    @Test func sichtungskategorie() {
        #expect(Sichtungskategorie.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6])
        #expect(Sichtungskategorie(rawValue: 5) == .ungesichtet)
        #expect(Sichtungskategorie(rawValue: 6) == .verstorben)
    }

    @Test func unitType() {
        #expect(UnitType.allCases.map(\.rawValue) == Array(0...11))
        #expect(UnitType(rawValue: 2) == .nef)
        #expect(UnitType(rawValue: 9) == .ktwKatS)
        #expect(UnitType(rawValue: 11) == .elw)
    }

    @Test func patientAttributes() {
        #expect(Gender.allCases.map(\.rawValue) == [-1, 0, 1])
        #expect(TraumaRoom.allCases.map(\.rawValue) == [0, 1, 2])
        #expect(HospitalRegistrationState.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(TreatmentPriority.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(BodySide.allCases.map(\.rawValue) == [0, 1])
        #expect(BodyRegion.allCases.map(\.rawValue) == Array(0...7))
        #expect(CirculationState.allCases.map(\.rawValue) == [0, 1, 2])
        #expect(CirculationState(legacyStable: true) == .stabil)
        #expect(CirculationState(legacyStable: false) == .unbekannt)
    }

    @Test func bodyRegionLegacyText() {
        #expect(BodyRegion(legacyText: "Wirbelsäule") == .wirbelsaeule)
        #expect(BodyRegion(legacyText: "Thorax") == .thorax)
        #expect(BodyRegion(legacyText: "Knie") == nil)
        #expect(BodyRegion(legacyText: nil) == nil)
    }

    @Test func missionTypeLegacyValues() {
        #expect(MissionType(legacyValue: "VU") == .verkehrsunfall)
        #expect(MissionType(legacyValue: "Polizei Sonderlage") == .polizeiSonderlage)
        #expect(MissionType(legacyValue: "Mehrfach erkrankt") == .mehrfachErkrankte)
        #expect(MissionType(legacyValue: "Einsatzart auswählen") == nil)
        #expect(MissionType(legacyValue: "  ") == nil)
        #expect(MissionType(legacyValue: nil) == nil)
    }

    @Test func codableUsesRawValues() throws {
        let encoded = try JSONEncoder().encode([Sichtungskategorie.sk2, .verstorben])
        #expect(String(decoding: encoded, as: UTF8.self) == "[2,6]")
        let decoded = try JSONDecoder().decode([UnitType].self, from: Data("[0,3]".utf8))
        #expect(decoded == [.rtw, .rth])
    }
}

@Suite("Sichtungskategorie")
struct SichtungskategorieTests {
    @Test func sortOrderMatchesLegacy() {
        let sorted = [Sichtungskategorie.verstorben, .sk3, .ungesichtet, .sk1].sorted()
        #expect(sorted == [.sk1, .sk3, .ungesichtet, .verstorben])
    }

    @Test func quickAddAndDefault() {
        #expect(Sichtungskategorie.quickAddCategories == [.sk1, .sk2, .sk3, .ungesichtet])
        #expect(Sichtungskategorie.defaultForNewPatient == .ungesichtet)
    }

    @Test func readableTextColors() {
        #expect(Sichtungskategorie.sk2.color.contrastingTextColor == .black)
        #expect(Sichtungskategorie.verstorben.color.contrastingTextColor == .white)
    }
}

@Suite("Alarmstichworte")
struct AlarmstichwortTests {
    @Test(arguments: [
        (Alarmstichwort.rd1, 1, 0),
        (.rd2, 1, 1),
        (.rd3, 2, 1),
        (.rd4, 4, 2),
        (.rd5, 5, 3),
    ])
    func unitCounts(stichwort: Alarmstichwort, rtw: Int, nef: Int) {
        let units = stichwort.unitsToCreate
        #expect(units.filter { $0 == .rtw }.count == rtw)
        #expect(units.filter { $0 == .nef }.count == nef)
        #expect(units.count == rtw + nef)
    }

    @Test func stableOrderAndSummary() {
        #expect(Alarmstichwort.rd3.unitsToCreate == [.rtw, .rtw, .nef])
        #expect(Alarmstichwort.rd3.summary == "2 RTW, 1 NEF")
        #expect(Alarmstichwort.rd1.summary == "1 RTW")
    }
}

@Suite("IVENA / PZC")
struct PatientAllocationCodeTests {
    @Test func completeCode() {
        let pzc = PatientAllocationCode(rmiCode: 361, ageInYears: 45, priority: .sofortigeIntervention)
        #expect(pzc.description == "361-45-1")
        #expect(pzc.isComplete)
    }

    @Test func padsAgeAndHandlesMissingValues() {
        #expect(PatientAllocationCode(rmiCode: 361, ageInYears: 7, priority: .vermutlichAmbulant).description == "361-07-3")
        #expect(PatientAllocationCode(rmiCode: nil, ageInYears: nil, priority: .keineDringlichkeit).description == "000-00-0")
        #expect(PatientAllocationCode(rmiCode: 42, ageInYears: 0, priority: .keineDringlichkeit).description == "000-00-0")
    }

    @Test func clampsHighAge() {
        let pzc = PatientAllocationCode(rmiCode: 100, ageInYears: 104, priority: .stationaereAufnahmeWahrscheinlich)
        #expect(pzc.description == "100-99-2")
    }

    @Test func incompleteWithoutPriority() {
        let pzc = PatientAllocationCode(rmiCode: 361, ageInYears: 45, priority: .keineDringlichkeit)
        #expect(!pzc.isComplete)
    }

    @Test func rmiValidity() {
        #expect(RMI(code: 361, title: "Beispiel", category: "Beispielkategorie").isValid)
        #expect(!RMI(code: 99, title: "", category: "").isValid)
    }
}
