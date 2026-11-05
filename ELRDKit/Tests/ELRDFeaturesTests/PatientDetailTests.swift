import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Patient – Personendaten")
@MainActor
struct PatientDetailTests {
    static let calendar = Calendar(identifier: .gregorian)
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 3))!

    static let birthCases: [(text: String, expected: String?)] = [
        ("14.03.1981", "14.03.1981"), ("14.3.81", "14.03.1981"), ("14031981", "14.03.1981"), ("140381", "14.03.1981"),
        ("1.1.05", "01.01.2005"), ("31.02.1990", nil), ("14.13.1981", nil), ("gestern", nil), ("14.03.198", nil), ("", nil),
    ]

    @Test(arguments: PatientDetailTests.birthCases)
    func birthDateParsing(text: String, expected: String?) {
        let parsed = BirthDateFormat.parse(text, now: Self.now, calendar: Self.calendar)
        #expect(parsed.map { BirthDateFormat.string(from: $0, calendar: Self.calendar) } == expected)
    }

    func makeStore() throws -> (MissionStore, Patient) {
        let store = try PreviewData.makeStore()
        let patient = try #require(store.state.activePatients.first)
        return (store, patient)
    }

    @Test func onlyEditedFieldsAreSavedAndOthersSurvive() throws {
        let (store, patient) = try makeStore()
        var form = PatientEditForm(patient: patient)
        form.lastName = " Mustermann "
        form.identifyingFeatures = "Fahrer Pkw rot"
        #expect(form.hasChanges(now: Self.now))

        // Inzwischen setzt jemand anderes die ILS-Nummer.
        try store.perform(EditPatient(patientID: patient.id) { $0.dispatchPatientNumber = "2614" })

        let snapshot = form
        let saved = try store.perform(EditPatient(patientID: patient.id) { snapshot.apply(to: &$0, now: Self.now) })
        #expect(saved.lastName == "Mustermann")
        #expect(saved.identifyingFeatures == "Fahrer Pkw rot")
        #expect(saved.dispatchPatientNumber == "2614", "fremde Änderung bleibt erhalten")

        form.markSaved(saved)
        #expect(!form.hasChanges(now: Self.now), "getrimmte Eingabe gilt als gespeichert")
        #expect(form.lastName == " Mustermann ", "Eingabetext bleibt beim Tippen unverändert")
    }

    @Test func birthDateWinsOverAge() throws {
        let (store, patient) = try makeStore()
        var form = PatientEditForm(patient: patient)
        form.age = "45"
        var snapshot = form
        var saved = try store.perform(EditPatient(patientID: patient.id) { snapshot.apply(to: &$0, now: Self.now) })
        #expect(saved.estimatedAge == 45)
        #expect(saved.birthDate == nil)

        form.markSaved(saved)
        form.birthDate = "14.03.1981"
        snapshot = form
        saved = try store.perform(EditPatient(patientID: patient.id) { snapshot.apply(to: &$0, now: Self.now) })
        #expect(saved.birthDate != nil)
        #expect(saved.estimatedAge == nil, "Geburtsdatum ersetzt die Schätzung")
        #expect(saved.age(at: Self.now, calendar: Self.calendar) == 45)
    }

    @Test func invalidInputIsReportedAndNotSaved() throws {
        let (store, patient) = try makeStore()
        var form = PatientEditForm(patient: patient)
        form.number = "12-A"
        form.birthDate = "31.02.1990"
        #expect(form.problems(now: Self.now) == [.numberInvalid, .birthDateInvalid])

        form.birthDate = ""
        form.age = "200"
        #expect(form.problems(now: Self.now) == [.numberInvalid, .ageInvalid])

        form.birthDate = "01.01.2030"
        #expect(form.problems(now: Self.now).contains(.birthDateInFuture))

        // Ungültige Nummer überschreibt die gespeicherte nicht.
        let snapshot = form
        let saved = try store.perform(EditPatient(patientID: patient.id) { snapshot.apply(to: &$0, now: Self.now) })
        #expect(saved.number == patient.number)
    }

    @Test func duplicateNumbersAreOnlyHints() throws {
        let (store, patient) = try makeStore()
        let others = store.state.activePatients.filter { $0.id != patient.id }
        try store.perform(EditPatient(patientID: others[0].id) { $0.dispatchPatientNumber = "4711" })

        var form = PatientEditForm(patient: patient)
        form.number = others[1].number.description
        form.dispatchNumber = "4711"
        let hints = form.duplicateHints(patientID: patient.id, among: store.state.patients)
        #expect(hints.count == 2)
        #expect(form.problems(now: Self.now).isEmpty, "Doppelte sind kein Fehler (E48)")

        // Speichern geht trotzdem.
        let snapshot = form
        let saved = try store.perform(EditPatient(patientID: patient.id) { snapshot.apply(to: &$0, now: Self.now) })
        #expect(saved.number == others[1].number)
        #expect(Patient.duplicateNumbers(in: store.state.patients).contains(saved.number))
    }

    @Test func searchFindsIdentifyingFeatures() throws {
        let (store, patient) = try makeStore()
        try store.perform(EditPatient(patientID: patient.id) { $0.identifyingFeatures = "Radfahrer, Helm grün" })
        let found = PatientListQuery(searchText: "helm").apply(to: store.state.patients)
        #expect(found.map(\.id) == [patient.id])
    }
}
