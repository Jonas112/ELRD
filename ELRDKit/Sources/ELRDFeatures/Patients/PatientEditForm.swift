import Foundation
import ELRDDomain

/// Geburtsdatum als Text: schnell tippbar statt Datumsrad.
///
/// Akzeptiert „14.03.1981“, „14.3.81“, „14031981“ und „140381“. Zweistellige Jahre
/// bis zum aktuellen Jahr gelten als 20xx, sonst 19xx.
enum BirthDateFormat {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%04d", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
    }

    static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var day: Int, month: Int, year: Int
        if trimmed.allSatisfy(\.isNumber), trimmed.count == 8 || trimmed.count == 6 {
            let digits = Array(trimmed)
            day = Int(String(digits[0...1]))!
            month = Int(String(digits[2...3]))!
            year = Int(String(digits[4...]))!
        } else {
            let pieces = trimmed.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == "-" || $0 == " " })
            guard pieces.count == 3, let d = Int(pieces[0]), let m = Int(pieces[1]), let y = Int(pieces[2]) else { return nil }
            guard pieces[2].count == 2 || pieces[2].count == 4 else { return nil }
            day = d; month = m; year = y
        }
        if year < 100 {
            let currentShort = calendar.component(.year, from: now) % 100
            year += year <= currentShort ? 2000 : 1900
        }
        guard (1...31).contains(day), (1...12).contains(month), (1880...9999).contains(year) else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else { return nil }
        return date
    }
}

/// Eingaben „Person“ und „Notiz“ eines Patienten.
///
/// Wie bei den Einsatzdaten werden nur geänderte Felder geschrieben (E60);
/// gespeichert wird automatisch kurz nach der letzten Eingabe.
struct PatientEditForm: Equatable {
    var number: String
    var dispatchNumber: String
    var firstName: String
    var lastName: String
    var birthDate: String
    var age: String
    var gender: Gender
    var isChild: Bool
    var identifyingFeatures: String
    var notes: String

    private var saved: Values

    /// Werte in gespeicherter Form (getrimmt, geparst).
    private struct Values: Equatable {
        var number: SerialNumber?
        var dispatchNumber: String
        var firstName: String
        var lastName: String
        var birthDate: Date?
        var age: Int?
        var gender: Gender
        var isChild: Bool
        var identifyingFeatures: String
        var notes: String
    }

    init(patient: Patient) {
        number = patient.number.description
        dispatchNumber = patient.dispatchPatientNumber ?? ""
        firstName = patient.firstName
        lastName = patient.lastName
        birthDate = patient.birthDate.map { BirthDateFormat.string(from: $0) } ?? ""
        age = patient.birthDate == nil ? patient.estimatedAge.map(String.init) ?? "" : ""
        gender = patient.gender
        isChild = patient.isChild
        identifyingFeatures = patient.identifyingFeatures ?? ""
        notes = patient.notes
        saved = Self.values(of: patient)
    }

    private static func values(of patient: Patient) -> Values {
        Values(
            number: patient.number,
            dispatchNumber: trimmed(patient.dispatchPatientNumber ?? ""),
            firstName: trimmed(patient.firstName),
            lastName: trimmed(patient.lastName),
            birthDate: patient.birthDate,
            age: patient.birthDate == nil ? patient.estimatedAge : nil,
            gender: patient.gender,
            isChild: patient.isChild,
            identifyingFeatures: trimmed(patient.identifyingFeatures ?? ""),
            notes: trimmed(patient.notes)
        )
    }

    // MARK: Prüfung

    enum Problem: Equatable {
        case numberInvalid
        case birthDateInvalid
        case birthDateInFuture
        case ageInvalid

        var message: String {
            switch self {
            case .numberInvalid: "Nummer bitte als Buchstabe und Zahl, z. B. A-12."
            case .birthDateInvalid: "Geburtsdatum bitte als TT.MM.JJJJ."
            case .birthDateInFuture: "Das Geburtsdatum liegt in der Zukunft."
            case .ageInvalid: "Alter bitte als Zahl zwischen 0 und 130."
            }
        }
    }

    func problems(now: Date) -> [Problem] {
        var result: [Problem] = []
        if SerialNumber(parsing: Self.trimmed(number)) == nil { result.append(.numberInvalid) }
        let birth = Self.trimmed(birthDate)
        if !birth.isEmpty {
            if let date = BirthDateFormat.parse(birth, now: now) {
                if date > now { result.append(.birthDateInFuture) }
            } else {
                result.append(.birthDateInvalid)
            }
        }
        let ageText = Self.trimmed(age)
        if birth.isEmpty, !ageText.isEmpty, Int(ageText).map({ !(0...Patient.maximumAge).contains($0) }) ?? true {
            result.append(.ageInvalid)
        }
        return result
    }

    /// Hinweise (sperren nichts, E48): doppelte eigene Nummer, doppelte ILS-Nummer.
    func duplicateHints(patientID: PatientID, among patients: [Patient]) -> [String] {
        let others = patients.active.filter { $0.id != patientID }
        var hints: [String] = []
        if let parsed = SerialNumber(parsing: Self.trimmed(number)), others.contains(where: { $0.number == parsed }) {
            hints.append("Die Nummer \(parsed) ist in diesem Einsatz schon vergeben.")
        }
        let ils = Self.trimmed(dispatchNumber)
        if !ils.isEmpty, let other = others.first(where: { Self.trimmed($0.dispatchPatientNumber ?? "").caseInsensitiveCompare(ils) == .orderedSame }) {
            hints.append("Die ILS-Nummer \(ils) hat auch Patient \(other.number).")
        }
        return hints
    }

    // MARK: Übernehmen

    private func current(now: Date) -> Values {
        let birth = Self.trimmed(birthDate)
        let parsedBirth = birth.isEmpty ? nil : BirthDateFormat.parse(birth, now: now)
        let ageText = Self.trimmed(age)
        return Values(
            number: SerialNumber(parsing: Self.trimmed(number)) ?? saved.number,
            dispatchNumber: Self.trimmed(dispatchNumber),
            firstName: Self.trimmed(firstName),
            lastName: Self.trimmed(lastName),
            // Ungültige Eingaben überschreiben den gespeicherten Wert nicht.
            birthDate: birth.isEmpty ? nil : (parsedBirth ?? saved.birthDate),
            age: (birth.isEmpty && !ageText.isEmpty) ? (Int(ageText) ?? saved.age) : nil,
            gender: gender,
            isChild: isChild,
            identifyingFeatures: Self.trimmed(identifyingFeatures),
            notes: Self.trimmed(notes)
        )
    }

    func hasChanges(now: Date) -> Bool { current(now: now) != saved }

    /// Schreibt nur die geänderten Felder.
    func apply(to patient: inout Patient, now: Date) {
        let values = current(now: now)
        if values.number != saved.number, let number = values.number { patient.number = number }
        if values.dispatchNumber != saved.dispatchNumber {
            patient.dispatchPatientNumber = values.dispatchNumber.isEmpty ? nil : values.dispatchNumber
        }
        if values.firstName != saved.firstName { patient.firstName = values.firstName }
        if values.lastName != saved.lastName { patient.lastName = values.lastName }
        if values.birthDate != saved.birthDate {
            patient.birthDate = values.birthDate
            if values.birthDate != nil { patient.estimatedAge = nil }
        }
        if values.age != saved.age, values.birthDate == nil {
            patient.estimatedAge = values.age
        }
        if values.gender != saved.gender { patient.gender = values.gender }
        if values.isChild != saved.isChild { patient.isChild = values.isChild }
        if values.identifyingFeatures != saved.identifyingFeatures {
            patient.identifyingFeatures = values.identifyingFeatures.isEmpty ? nil : values.identifyingFeatures
        }
        if values.notes != saved.notes { patient.notes = values.notes }
    }

    /// Nach dem Speichern: Vergleichsstand übernehmen, die Eingabetexte bleiben
    /// unverändert (kein Springen des Cursors, kein Abschneiden beim Tippen).
    mutating func markSaved(_ patient: Patient) {
        saved = Self.values(of: patient)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
