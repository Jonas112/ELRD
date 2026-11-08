import Foundation

/// Verbleib eines Patienten für die Personenauskunft (Schritt 93): wer, wohin, womit,
/// wann. Enthält Namen – nur für berechtigte Stellen (Personenauskunftsstelle,
/// Polizei, Angehörigenbetreuung).
public struct PatientWhereabouts: Identifiable, Equatable, Sendable {
    public enum Place: String, Sendable {
        case onScene, transported, released, deceased
    }

    public let id: PatientID
    public let number: String
    public let tagNumber: String?
    /// „Muster, Max“ oder leer.
    public let name: String
    /// Geburtsdatum „12.03.1980“ oder „ca. 45 J.“, sonst leer.
    public let birth: String
    public let gender: Gender
    public let triage: Sichtungskategorie
    public let place: Place
    /// „Klinikum Nord“, „Vor Ort entlassen“, „Noch vor Ort“ …
    public let whereabouts: String
    /// „mit RK 1 ab 12:30“, „Abschnitt Patientenablage“ …
    public let detail: String
    /// Suchtext (Name, Nummern, Merkmale) in Kleinbuchstaben.
    private let searchText: String

    public static func list(patients: [Patient], units: [MissionUnit], sections: [MissionSection], now: Date) -> [PatientWhereabouts] {
        let unitNames = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0.displayName) })
        let sectionNames = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.name) })
        return Patient.sortedByNumber(patients.active).map { patient in
            let assigned = patient.unitIDs.compactMap { unitNames[$0] }
            var place = Place.onScene
            var whereabouts = "Noch vor Ort"
            var detail: [String] = []
            switch patient.outcome {
            case .transported(let start)?:
                place = .transported
                whereabouts = patient.destination?.name ?? "Transport, Ziel unbekannt"
                if !assigned.isEmpty { detail.append("mit \(assigned.joined(separator: ", "))") }
                detail.append("ab \(time(start)) Uhr")
            case .released(let at, let handledBy)?:
                place = .released
                whereabouts = "Vor Ort entlassen"
                detail.append("\(time(at)) Uhr")
                if !handledBy.isEmpty { detail.append("versorgt von \(handledBy.joined(separator: ", "))") }
            case nil:
                if patient.triage == .verstorben {
                    place = .deceased
                    whereabouts = "Verstorben"
                }
                if let section = patient.sectionID.flatMap({ sectionNames[$0] }) { detail.append(section) }
                if !assigned.isEmpty { detail.append(assigned.joined(separator: ", ")) }
                if let destination = patient.destination?.name, place == .onScene { detail.append("Ziel \(destination)") }
            }
            return PatientWhereabouts(
                id: patient.id,
                number: patient.number.description,
                tagNumber: patient.tagNumber,
                name: patient.fullName,
                birth: birthText(patient, now: now),
                gender: patient.gender,
                triage: patient.triage,
                place: place,
                whereabouts: whereabouts,
                detail: detail.joined(separator: " · "),
                searchText: [
                    patient.fullName, patient.firstName, patient.lastName, patient.number.description,
                    patient.tagNumber ?? "", patient.dispatchPatientNumber ?? "", patient.identifyingFeatures ?? "",
                ].joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            )
        }
    }

    /// Alle Suchwörter müssen vorkommen (Groß/klein und Akzente egal).
    public func matches(_ query: String) -> Bool {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { searchText.contains($0) }
    }

    private static func birthText(_ patient: Patient, now: Date) -> String {
        if let birthDate = patient.birthDate { return dateFormatter.string(from: birthDate) }
        if let age = patient.estimatedAge { return "ca. \(age) J." }
        return ""
    }

    private static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
