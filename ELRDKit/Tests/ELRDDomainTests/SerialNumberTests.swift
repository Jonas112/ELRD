import Foundation
import Testing
@testable import ELRDDomain

@Suite("Nummern mit Gerätepräfix")
struct SerialNumberTests {
    @Test func displayAndValidation() {
        #expect(SerialNumber(prefix: "a", value: 12)?.description == "A-12")
        #expect(SerialNumber(prefix: "", value: 7)?.description == "7")
        #expect(SerialNumber(prefix: "AB", value: 1)?.description == "AB-1")
        #expect(SerialNumber(prefix: "ABC", value: 1) == nil)
        #expect(SerialNumber(prefix: "Ä", value: 1) == nil)
        #expect(SerialNumber(prefix: "1", value: 1) == nil)
        #expect(SerialNumber(prefix: "A", value: 0) == nil)
    }

    @Test(arguments: [
        ("A-12", "A-12"), ("a12", "A-12"), (" b - 3 ", "B-3"), ("AB-07", "AB-7"), ("15", "15"),
    ])
    func parsing(input: String, expected: String) {
        #expect(SerialNumber(parsing: input)?.description == expected)
    }

    @Test(arguments: ["", "A", "A-", "ABC-1", "1A", "A-1B", "A-٣"])
    func invalidParsing(input: String) {
        #expect(SerialNumber(parsing: input) == nil)
    }

    @Test func sortingIsNumericWithinPrefix() {
        let numbers = ["B-1", "A-10", "A-2", "3"].compactMap(SerialNumber.init(parsing:))
        #expect(numbers.sorted().map(\.description) == ["3", "A-2", "A-10", "B-1"])
    }

    @Test func nextOnlyLooksAtOwnPrefix() {
        let existing = ["A-1", "A-4", "B-9", "12"].compactMap(SerialNumber.init(parsing:))
        #expect(SerialNumber.next(prefix: "A", existing: existing).description == "A-5")
        #expect(SerialNumber.next(prefix: "b", existing: existing).description == "B-10")
        #expect(SerialNumber.next(prefix: "C", existing: existing).description == "C-1")
    }

    @Test func codableAsTextAndLegacyNumber() throws {
        let number = SerialNumber(prefix: "A", value: 12)!
        let data = try JSONEncoder().encode(number)
        #expect(String(decoding: data, as: UTF8.self) == "\"A-12\"")
        #expect(try JSONDecoder().decode(SerialNumber.self, from: data) == number)
        #expect(try JSONDecoder().decode(SerialNumber.self, from: Data("42".utf8)).description == "42")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SerialNumber.self, from: Data("\"A-\"".utf8))
        }
    }

    @Test func deviceIdentity() {
        #expect(DeviceIdentity(deviceID: DeviceID(), numberPrefix: "c")?.numberPrefix == "C")
        #expect(DeviceIdentity(deviceID: DeviceID(), numberPrefix: "") == nil)
        #expect(DeviceIdentity.defaultPrefix == "A")
    }

    @Test func patientsFromTwoDevicesDoNotCollide() {
        let missionID = MissionID()
        func patient(_ number: SerialNumber) -> Patient {
            Patient(missionID: missionID, metadata: .new(by: nil, at: Fixture.start), number: number)
        }
        var patients: [Patient] = []
        patients.append(patient(Patient.nextNumber(prefix: "A", existing: patients)))
        patients.append(patient(Patient.nextNumber(prefix: "B", existing: patients)))
        patients.append(patient(Patient.nextNumber(prefix: "A", existing: patients)))
        #expect(patients.map(\.number.description) == ["A-1", "B-1", "A-2"])
        #expect(Patient.duplicateNumbers(in: patients).isEmpty)
    }
}
