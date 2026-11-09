import Foundation

/// Übergabe eines Patienten im ATMIST-Schema (Schritt 97): Alter, Zeit, Mechanismus,
/// Injuries/Verletzungen, Zeichen, Therapie. Zum Vorlesen oder Teilen an Klinik
/// oder Transportbesatzung – enthält den Namen, falls bekannt.
public enum ATMISTHandover {
    public static func text(patient: Patient, mission: Mission, units: [MissionUnit], now: Date) -> String {
        let time = Self.time
        var lines = ["Übergabe Patient \(patient.number) (\(patient.triage.shortName)) – ATMIST"]
        let name = patient.fullName
        if !name.isEmpty { lines.append("Name: \(name)") }

        var age: [String] = []
        if let birth = patient.birthDate {
            age.append("geb. \(Self.date(birth))" + (patient.age(at: now).map { " (\($0) J.)" } ?? ""))
        } else if let estimated = patient.estimatedAge {
            age.append("ca. \(estimated) J.")
        } else if patient.isChild {
            age.append("Kind")
        }
        if patient.gender != .unklar { age.append(patient.gender.displayName) }
        lines.append("A – Alter: " + (age.isEmpty ? "unbekannt" : age.joined(separator: ", ")))

        var times = ["Einsatzbeginn \(time(mission.startedAt))", "erfasst \(time(patient.metadata.createdAt))"]
        if let triaged = patient.firstTriagedAt { times.append("gesichtet \(time(triaged))") }
        if case .transported(let start)? = patient.outcome { times.append("Transport ab \(time(start))") }
        lines.append("T – Zeit: " + times.joined(separator: ", "))

        let mechanism = [mission.type?.displayName, mission.reason.isEmpty ? nil : mission.reason]
            .compactMap { $0 }.joined(separator: " – ")
        lines.append("M – Mechanismus: " + (mechanism.isEmpty ? "nicht angegeben" : mechanism))

        let injuries = patient.injuries.map(\.displayText)
        lines.append("I – Verletzungen: " + (injuries.isEmpty ? "keine erfasst" : injuries.joined(separator: "; ")))

        var signs = [patient.triage.displayName]
        if patient.circulation != .unbekannt { signs.append(patient.circulation.displayName) }
        if let abcd = patient.abcd, !abcd.summary.isEmpty { signs.append("ABCD \(abcd.summary)") }
        if patient.traumaRoom != .none { signs.append(patient.traumaRoom.displayName) }
        lines.append("S – Zeichen: " + signs.joined(separator: ", "))

        var treatment: [String] = []
        if patient.isIntubated { treatment.append("intubiert") }
        let note = patient.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { treatment.append(note) }
        let unitNames = patient.unitIDs.compactMap { id in units.first { $0.id == id }?.displayName }
        if !unitNames.isEmpty { treatment.append("versorgt von \(unitNames.joined(separator: ", "))") }
        lines.append("T – Therapie: " + (treatment.isEmpty ? "keine Angaben" : treatment.joined(separator: "; ")))

        if let destination = patient.destination?.name { lines.append("Ziel: \(destination)") }
        return lines.joined(separator: "\n")
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
}

/// Voranmeldung an eine Zielklinik (Schritt 98): wie viele Patienten welcher
/// Kategorie kommen, womit, wann abgefahren – ohne Namen.
public struct HospitalPreannouncement: Identifiable, Equatable, Sendable {
    public let id: String
    public let hospitalName: String
    public let email: String?
    public let patientCount: Int
    public let text: String

    public static func all(mission: Mission, patients: [Patient], units: [MissionUnit]) -> [HospitalPreannouncement] {
        let withDestination = Patient.sortedByNumber(patients.active).filter { $0.destination != nil && $0.triage != .verstorben }
        let groups = Dictionary(grouping: withDestination) { HospitalQuota.key($0.destination?.name ?? "") }
        return groups.values.compactMap { group -> HospitalPreannouncement? in
            guard let hospital = group.first?.destination else { return nil }
            let counts = [Sichtungskategorie.sk1, .sk2, .sk3, .ungesichtet, .unverletzt].compactMap { category -> String? in
                let count = group.filter { $0.triage == category }.count
                return count > 0 ? "\(count) × \(category.shortName)" : nil
            }
            var lines = [
                mission.isExerciseMission ? "ÜBUNG – Voranmeldung Einsatz \(mission.displayNumber())" : "Voranmeldung Einsatz \(mission.displayNumber())",
                "Einsatz: \(mission.title)",
                "An: \(hospital.name)",
                "Patienten: \(group.count) (\(counts.joined(separator: ", ")))",
            ]
            for patient in group {
                var parts = ["\(patient.number) \(patient.triage.shortName)"]
                if let age = patient.estimatedAge { parts.append("ca. \(age) J.") }
                if patient.gender != .unklar { parts.append(patient.gender.displayName) }
                let injuries = patient.injuries.prefix(2).map(\.displayText)
                if !injuries.isEmpty { parts.append(injuries.joined(separator: ", ")) }
                if patient.traumaRoom != .none { parts.append(patient.traumaRoom.displayName) }
                let unitNames = patient.unitIDs.compactMap { id in units.first { $0.id == id && $0.type.transportsPatients }?.displayName }
                if case .transported(let start)? = patient.outcome {
                    parts.append("unterwegs seit \(ATMISTHandover.time(start))" + (unitNames.isEmpty ? "" : " mit \(unitNames.joined(separator: ", "))"))
                } else {
                    parts.append(unitNames.isEmpty ? "noch vor Ort" : "vor Ort, eingeteilt \(unitNames.joined(separator: ", "))")
                }
                lines.append("– " + parts.joined(separator: " · "))
            }
            let email = hospital.email.trimmingCharacters(in: .whitespacesAndNewlines)
            return HospitalPreannouncement(
                id: HospitalQuota.key(hospital.name),
                hospitalName: hospital.name,
                email: email.contains("@") ? email : nil,
                patientCount: group.count,
                text: lines.joined(separator: "\n")
            )
        }
        .sorted { $0.hospitalName.localizedCaseInsensitiveCompare($1.hospitalName) == .orderedAscending }
    }
}
