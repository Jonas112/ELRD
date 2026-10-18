import Foundation
import Testing
@testable import ELRDDomain

private extension Fixture {
    static let missionID = MissionID()

    static func patient(number: Int = 1, triage: Sichtungskategorie = .ungesichtet) -> Patient {
        Patient(
            missionID: missionID,
            metadata: .new(by: author, at: start),
            number: number,
            triage: triage
        )
    }
}

@Suite("Verletzungen")
struct InjuryTests {
    @Test func sideOnlyForRegionsWithSide() {
        let leg = Injury(diagnosis: " Fraktur ", region: .unterschenkel, side: .rechts)
        #expect(leg.diagnosis == "Fraktur")
        #expect(leg.displayText == "Fraktur Unterschenkel rechts")

        let chest = Injury(diagnosis: "Prellung", region: .thorax, side: .links)
        #expect(chest.side == nil)
        #expect(chest.displayText == "Prellung Thorax")

        var moved = leg
        moved.setLocation(region: .kopf, side: .links)
        #expect(moved.side == nil)
        #expect(Injury(diagnosis: "Unklar").displayText == "Unklar")
    }
}

@Suite("Patient")
struct PatientTests {
    @Test func defaultsForNewPatient() {
        let patient = Fixture.patient()
        #expect(patient.triage == .ungesichtet)
        #expect(patient.gender == .unklar)
        #expect(patient.status == .waiting)
        #expect(patient.displayName == "P 1")
    }

    @Test func names() {
        var patient = Fixture.patient(number: 12)
        patient.lastName = " Muster "
        #expect(patient.displayName == "P 12 – Muster")
        patient.firstName = "Max"
        #expect(patient.fullName == "Muster, Max")
        patient.lastName = ""
        #expect(patient.fullName == "Max")
    }

    @Test func ageFromBirthDateHasPriority() {
        var patient = Fixture.patient()
        patient.estimatedAge = 40
        #expect(patient.age(at: Fixture.start, calendar: Fixture.calendar) == 40)

        patient.birthDate = Fixture.date(1980, 10, 19)
        #expect(patient.age(at: Fixture.start, calendar: Fixture.calendar) == 45, "Geburtstag ist erst morgen")
        patient.birthDate = Fixture.date(1980, 10, 18, 0, 0)
        #expect(patient.age(at: Fixture.start, calendar: Fixture.calendar) == 46)
        patient.birthDate = Fixture.date(2030, 1, 1)
        #expect(patient.age(at: Fixture.start, calendar: Fixture.calendar) == nil)
    }

    @Test func setAgeShiftsBirthDateLikeLegacy() {
        var patient = Fixture.patient()
        patient.birthDate = Fixture.date(1990, 3, 5)
        patient.setAge(30, at: Fixture.start, calendar: Fixture.calendar)
        let components = Fixture.calendar.dateComponents([.year, .month, .day], from: patient.birthDate!)
        #expect(components.year == 1996)
        #expect(components.month == 3)
        #expect(components.day == 5)

        var withoutBirthDate = Fixture.patient()
        withoutBirthDate.setAge(7, at: Fixture.start, calendar: Fixture.calendar)
        #expect(withoutBirthDate.estimatedAge == 7)
        withoutBirthDate.setAge(500, at: Fixture.start, calendar: Fixture.calendar)
        #expect(withoutBirthDate.estimatedAge == nil)
    }

    @Test func injuriesIgnoreEmptyAndDuplicates() {
        var patient = Fixture.patient()
        let fracture = Injury(diagnosis: "Fraktur", region: .arm, side: .links)
        patient.addInjury(fracture)
        patient.addInjury(fracture)
        patient.addInjury(Injury(diagnosis: "   "))
        #expect(patient.injuries.count == 1)

        var changed = fracture
        changed.diagnosis = "Luxation"
        patient.updateInjury(changed)
        #expect(patient.injuries.first?.diagnosis == "Luxation")

        patient.removeInjury(fracture.id)
        #expect(patient.injuries.isEmpty)
    }

    @Test func medicalSummaryOrder() {
        var patient = Fixture.patient()
        patient.addInjury(Injury(diagnosis: "SHT", region: .kopf))
        patient.traumaRoom = .a
        patient.isIntubated = true
        patient.isCirculationUnstable = true
        #expect(patient.medicalSummaryLines == ["SHT Kopf", "Schockraum A", "Intubiert / beatmet", "Kreislauf instabil"])
    }

    @Test func allocationCodeUsesAge() {
        var patient = Fixture.patient()
        patient.rmiCode = 361
        patient.estimatedAge = 8
        patient.treatmentPriority = .sofortigeIntervention
        #expect(patient.allocationCode(at: Fixture.start).description == "361-08-1")
    }
}

@Suite("Patient – Einheiten und Transport")
struct PatientTransportTests {
    @Test func assignmentLifecycle() {
        var patient = Fixture.patient()
        let rtw = UnitID()
        let nef = UnitID()
        patient.assign(unit: rtw)
        patient.assign(unit: nef)
        patient.assign(unit: rtw)
        #expect(patient.unitIDs == [rtw, nef])
        #expect(patient.status == .assigned)

        patient.startTransport(at: Fixture.start)
        #expect(patient.status == .inTransport)
        #expect(patient.outcome == .transported(startedAt: Fixture.start))

        patient.startTransport(at: Fixture.start.addingTimeInterval(60))
        #expect(patient.outcome?.date == Fixture.start, "Zweiter Start ändert nichts")

        patient.resetOutcome()
        #expect(patient.status == .assigned)
    }

    @Test func releaseRemembersUnitNamesAndDetaches() {
        var patient = Fixture.patient()
        let rtw = UnitID()
        let nef = UnitID()
        patient.assign(unit: rtw)
        patient.assign(unit: nef)
        patient.setDestination(HospitalSnapshot(name: "Klinikum", city: "Musterstadt"))
        patient.registrationState = .angemeldet

        let names: [UnitID: String] = [rtw: "RTW 1", nef: "NEF 1"]
        patient.release(at: Fixture.start, unitNames: { names[$0] }, clearDestination: true)

        #expect(patient.status == .released)
        #expect(patient.unitIDs.isEmpty)
        #expect(patient.destination == nil)
        #expect(patient.registrationState == .unklar)
        #expect(patient.outcome == .released(at: Fixture.start, handledBy: ["RTW 1", "NEF 1"]))

        patient.assign(unit: rtw)
        #expect(patient.unitIDs.isEmpty, "Entlassene Patienten bekommen keine Einheit mehr")
    }

    @Test func releaseCanKeepDestination() {
        var patient = Fixture.patient()
        patient.setDestination(HospitalSnapshot(name: "Klinikum"))
        patient.release(at: Fixture.start, unitNames: { _ in nil }, clearDestination: false)
        #expect(patient.destination?.name == "Klinikum")
    }

    @Test func changingDestinationResetsRegistration() {
        var patient = Fixture.patient()
        let master = MasterHospitalID()
        patient.setDestination(HospitalSnapshot(name: "Klinikum A", masterHospitalID: master))
        patient.registrationState = .angemeldet
        patient.setDestination(HospitalSnapshot(name: "Klinikum A", phone: "0123", masterHospitalID: master))
        #expect(patient.registrationState == .angemeldet, "Gleiche Klinik behält den Status")
        patient.setDestination(HospitalSnapshot(name: "Klinikum B"))
        #expect(patient.registrationState == .unklar)
        #expect(HospitalSnapshot(name: "Klinikum B", city: "Musterstadt").displayName == "Klinikum B / Musterstadt")
    }

    @Test func unitIsFreeWhenNoActivePatient() {
        let unit = MissionUnit(
            missionID: Fixture.missionID,
            metadata: .new(by: Fixture.author, at: Fixture.start),
            type: .rtw,
            callsign: "RTW 1"
        )
        var patient = Fixture.patient()
        #expect(unit.isFree(in: [patient]))
        patient.assign(unit: unit.id)
        #expect(!unit.isFree(in: [patient]))
        #expect(unit.patients(in: [patient]).map(\.id) == [patient.id])
        patient.metadata.markDeleted(by: Fixture.author, at: Fixture.start)
        #expect(unit.isFree(in: [patient]))
    }
}

@Suite("Patienten – Sammlungen")
struct PatientCollectionTests {
    @Test func numberingAndDuplicates() {
        let patients = [
            Fixture.patient(number: 1),
            Fixture.patient(number: 3),
            Fixture.patient(number: 3),
            Fixture.patient(number: 5),
        ]
        #expect(Patient.nextNumber(existing: patients) == 6)
        #expect(Patient.nextNumber(existing: []) == 1)
        #expect(Patient.duplicateNumbers(in: patients) == [3])
    }

    @Test func countsAndSorting() {
        var deleted = Fixture.patient(number: 9, triage: .sk1)
        deleted.metadata.markDeleted(by: Fixture.author, at: Fixture.start)
        let patients = [
            Fixture.patient(number: 2, triage: .sk3),
            Fixture.patient(number: 3, triage: .sk1),
            Fixture.patient(number: 1, triage: .sk3),
            deleted,
        ]
        let counts = Patient.countsByTriage(patients)
        #expect(counts[.sk1] == 1)
        #expect(counts[.sk3] == 2)
        #expect(counts[.verstorben] == 0)
        #expect(Patient.sortedByTriage(patients).map(\.number) == [3, 1, 2])
        #expect(Patient.sortedByNumber(patients).map(\.number) == [1, 2, 3])
    }
}
