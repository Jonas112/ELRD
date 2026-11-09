import Foundation

/// Nachbesprechung eines Einsatzes (Schritt 107): wer war dabei, was lief gut, was
/// wird besser, wer kümmert sich um was. Kennzahlen und Zeitstrahl kommen aus
/// `MissionMetrics` und werden nicht gespeichert.
public struct MissionDebrief: Codable, Hashable, Sendable {
    public var conductedAt: Date?
    public var participants: String
    public var wentWell: String
    public var toImprove: String
    /// Maßnahmen mit Zuständigkeit, eine je Zeile.
    public var actions: String

    public init(conductedAt: Date? = nil, participants: String = "", wentWell: String = "", toImprove: String = "", actions: String = "") {
        self.conductedAt = conductedAt
        self.participants = participants
        self.wentWell = wentWell
        self.toImprove = toImprove
        self.actions = actions
    }

    public var isEmpty: Bool {
        [participants, wentWell, toImprove, actions].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Unbekannte oder fehlende Felder anderer Versionen → leer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conductedAt = try container.decodeIfPresent(Date.self, forKey: .conductedAt)
        participants = try container.decodeIfPresent(String.self, forKey: .participants) ?? ""
        wentWell = try container.decodeIfPresent(String.self, forKey: .wentWell) ?? ""
        toImprove = try container.decodeIfPresent(String.self, forKey: .toImprove) ?? ""
        actions = try container.decodeIfPresent(String.self, forKey: .actions) ?? ""
    }
}

/// Text der Nachbesprechung zum Teilen: Einsatzdaten, Kennzahlen, Meilensteine und
/// die Ergebnisse – ohne Patientennamen.
public enum MissionDebriefText {
    public static func text(mission: Mission, patients: [Patient], journal: [JournalEntry], now: Date) -> String {
        let metrics = MissionMetrics(mission: mission, patients: patients, journal: journal, now: now)
        let debrief = mission.debrief ?? MissionDebrief()
        var lines = [
            "\(mission.isExerciseMission ? "ÜBUNG – " : "")Nachbesprechung Einsatz \(mission.displayNumber())",
            mission.title,
        ]
        if let date = debrief.conductedAt { lines.append("Durchgeführt: \(dateTime(date))") }
        if !debrief.participants.isBlank { lines += ["", "Teilnehmende:", debrief.participants.trimmed] }

        lines += ["", "Kennzahlen:"]
        lines.append("– Patienten: \(metrics.patientCount)")
        for (label, date) in [
            ("Erste Sichtung", metrics.firstTriageAt), ("Alle gesichtet", metrics.allTriagedAt),
            ("Erster Transport", metrics.firstTransportAt), ("Letzter Patient versorgt", metrics.lastPatientGoneAt),
        ] {
            if let minutes = metrics.minutesFromStart(date) { lines.append("– \(label): +\(minutes) min") }
        }
        for category in [Sichtungskategorie.sk1, .sk2, .sk3] {
            if let wait = metrics.waits[category] {
                lines.append("– Wartezeit \(category.shortName): Ø \(wait.averageMinutes) min, längste \(wait.maximumMinutes) min")
            }
        }
        if let end = mission.endedAt {
            lines.append("– Dauer: \(max(0, Int(end.timeIntervalSince(mission.startedAt) / 60))) min")
        }

        lines += ["", "Meilensteine:"]
        for milestone in metrics.milestones {
            let offset = metrics.minutesFromStart(milestone.date).map { " (+\($0) min)" } ?? ""
            let detail = milestone.detail.map { " – \($0)" } ?? ""
            lines.append("– \(time(milestone.date))\(offset) \(milestone.title)\(detail)")
        }

        for (title, value) in [("Was lief gut:", debrief.wentWell), ("Was verbessern:", debrief.toImprove), ("Maßnahmen / zuständig:", debrief.actions)] where !value.isBlank {
            lines += ["", title, value.trimmed]
        }
        return lines.joined(separator: "\n")
    }

    static func time(_ date: Date) -> String { formatter("HH:mm").string(from: date) }
    static func dateTime(_ date: Date) -> String { formatter("dd.MM.yyyy HH:mm").string(from: date) }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = format
        return formatter
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}
