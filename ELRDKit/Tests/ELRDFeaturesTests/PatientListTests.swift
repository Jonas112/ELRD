import Foundation
import SwiftUI
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Patientenliste")
@MainActor
struct PatientListTests {
    static let start = Date(timeIntervalSince1970: 1_792_000_000)

    static func patient(_ number: Int, _ triage: Sichtungskategorie, prefix: String = "A") -> Patient {
        Patient(
            missionID: MissionID(),
            metadata: .new(by: nil, at: start),
            number: SerialNumber(prefix: prefix, value: number)!,
            triage: triage
        )
    }

    @Test func triageSortPutsOpenFirstThenSKThenNumber() {
        var transported = Self.patient(1, .sk1)
        transported.startTransport(at: Self.start)
        let patients = [
            transported,
            Self.patient(5, .ungesichtet),
            Self.patient(3, .sk2),
            Self.patient(2, .sk1),
            Self.patient(4, .sk2),
            Self.patient(6, .unverletzt),
        ]
        let sorted = PatientListQuery().apply(to: patients).map(\.number.description)
        #expect(sorted == ["A-2", "A-3", "A-4", "A-5", "A-6", "A-1"], "SK 1, SK 2, ungesichtet, unverletzt; Transport ans Ende")

        let byNumber = PatientListQuery(sort: .number).apply(to: patients).map(\.number.description)
        #expect(byNumber == ["A-1", "A-2", "A-3", "A-4", "A-5", "A-6"])
    }

    @Test func triageAndStatusFilterCombine() {
        var transported = Self.patient(1, .sk1)
        transported.startTransport(at: Self.start)
        let patients = [transported, Self.patient(2, .sk1), Self.patient(3, .sk2)]

        let sk1 = PatientListQuery(triage: .sk1)
        #expect(sk1.apply(to: patients).count == 2)
        let counts = sk1.statusCounts(in: patients)
        #expect(counts[.all] == 2)
        #expect(counts[.waiting] == 1)
        #expect(counts[.inTransport] == 1)

        let sk1Waiting = PatientListQuery(status: .waiting, triage: .sk1)
        #expect(sk1Waiting.apply(to: patients).map(\.number.description) == ["A-2"])
        #expect(sk1Waiting.isFiltered)
        #expect(!PatientListQuery().isFiltered)
    }

    @Test(arguments: [
        ("a-2", 1), ("A2", 1), ("müller", 1), ("MULLER", 1), ("4711", 1), ("eingeklemmt", 1), ("b-1", 1), ("x", 0), ("", 4),
    ] as [(String, Int)])
    func searchFindsNumbersNamesAndNotes(query: String, expected: Int) {
        var named = Self.patient(2, .sk2)
        named.lastName = "Müller"
        named.dispatchPatientNumber = "4711-01"
        var noted = Self.patient(3, .sk1)
        noted.notes = "Fahrer, eingeklemmt"
        let patients = [Self.patient(1, .sk3), named, noted, Self.patient(1, .sk3, prefix: "B")]
        #expect(PatientListQuery(searchText: query).apply(to: patients).count == expected)
    }

    @Test func deletedPatientsAreHidden() throws {
        let store = try PreviewData.makeStore()
        let first = try #require(store.state.activePatients.first)
        try store.perform(DeletePatient(patientID: first.id))
        let listed = PatientListQuery().apply(to: store.state.patients)
        #expect(listed.count == 6)
        #expect(!listed.contains { $0.id == first.id })
    }

    @Test func rowShowsUnitHintDuplicateAndDetails() throws {
        let store = try PreviewData.makeStore()
        let now = Date()
        var patients = store.state.patients
        // Zwei Patienten mit gleicher Nummer (z. B. von zwei Geräten mit gleichem Präfix).
        patients.append(Self.patient(1, .sk3))
        // Reihenfolge im Stand ist nach Anlage, nicht nach Nummer – daher über die Nummer suchen.
        let index = try #require(patients.firstIndex { $0.number.description == "A-1" })
        patients[index].firstName = "Thomas"
        patients[index].lastName = "Mustermann"
        patients[index].gender = .maennlich
        patients[index].estimatedAge = 45
        patients[index].dispatchPatientNumber = "2614"

        var state = store.state
        state.patients = patients
        let rows = PatientRow.rows(for: PatientListQuery(sort: .number).apply(to: patients), state: state, now: now)
        let first = try #require(rows.first { $0.id == patients[index].id })
        #expect(first.name == "Mustermann, Thomas")
        #expect(first.details == "ILS 2614 · m ~45 J")
        #expect(first.unitText == "keine Einheit")
        #expect(!first.hasUnit)
        #expect(first.isDuplicateNumber)
        #expect(rows.filter(\.isDuplicateNumber).count == 2)

        let unnamed = try #require(rows.first { $0.number == "A-2" })
        #expect(unnamed.name == nil)
        #expect(!unnamed.isDuplicateNumber)
    }

    @Test func viewsCanBeBuilt() throws {
        let store = try PreviewData.makeStore()
        var query = PatientListQuery()
        let binding = Binding(get: { query }, set: { query = $0 })
        _ = PatientsView(store: store, query: binding, onQuickAdd: { _ in }).body
        let id = try #require(store.state.activePatients.first?.id)
        _ = PatientDetailView(store: store, patientID: id, order: [id], onNavigate: { _ in }).body
    }
}
