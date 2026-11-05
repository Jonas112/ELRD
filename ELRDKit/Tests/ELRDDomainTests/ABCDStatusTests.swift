import Foundation
import Testing
@testable import ELRDDomain

@Suite("ABCD-Status (IVENA Prio 1)")
struct ABCDStatusTests {
    @Test func levelsMatchTheScheme() {
        for letter in ABCDLetter.allCases {
            #expect(letter.levels.count == 4)
            #expect(letter.shortLevels.count == 4)
        }
        #expect(ABCDLetter.airway.levels[2] == "gesichert (z. B. SGA, ITN, Koniotomie)")
        #expect(ABCDLetter.circulation.levels[2] == "stabil unter kontinuierlicher Katecholamintherapie")
        #expect(ABCDLetter.disability.levels[3] == "sediert / narkotisiert")
        #expect(ABCDLetter.breathing.code(3) == "B3")
    }

    @Test func onlyLevelsOneToFourAreKept() {
        var status = ABCDStatus(airway: 5, breathing: 2)
        #expect(status.airway == nil)
        #expect(status[.breathing] == 2)
        status[.circulation] = 0
        #expect(status.circulation == nil)
        status[.disability] = 4
        #expect(status.summary == "A– B2 C– D4")
        #expect(!status.isEmpty)
        #expect(ABCDStatus().isEmpty)
    }

    @Test func doesNotChangeAllocationCode() {
        var patient = Patient(
            missionID: MissionID(),
            metadata: .new(by: nil, at: Date()),
            number: SerialNumber(prefix: "A", value: 1)!,
            estimatedAge: 45,
            rmiCode: 212,
            treatmentPriority: .sofortigeIntervention
        )
        let before = patient.allocationCode(at: Date()).description
        patient.abcd = ABCDStatus(airway: 2, breathing: 2, circulation: 3, disability: 2)
        #expect(patient.allocationCode(at: Date()).description == before)
        #expect(before == "212-45-1")
    }

    @Test func olderPatientsWithoutABCDDecode() throws {
        let patient = Patient(
            missionID: MissionID(),
            metadata: .new(by: nil, at: Date(timeIntervalSince1970: 0)),
            number: SerialNumber(prefix: "A", value: 1)!,
            abcd: ABCDStatus(airway: 1)
        )
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(patient)) as? [String: Any])
        object.removeValue(forKey: "abcd")
        let decoded = try JSONDecoder().decode(Patient.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.abcd == nil)
    }
}
