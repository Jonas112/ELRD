import Foundation

/// Kennzahlen und Meilensteine eines Einsatzes (Schritt 86) – für den Verlauf in
/// der App und das Kapitel „Einsatzdaten“ im Bericht. Zeiten ab Einsatzbeginn.
public struct MissionMetrics: Equatable, Sendable {
    public enum MilestoneKind: String, Sendable {
        case start, firstPatient, firstTriage, allTriaged, firstTransport
        case situationReport, request, handover, lastPatientGone, end
    }

    public struct Milestone: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: MilestoneKind
        public let date: Date
        public let title: String
        public let detail: String?
    }

    /// Wartezeit bis Transportbeginn je Kategorie (nur abtransportierte Patienten).
    public struct Wait: Equatable, Sendable {
        public let count: Int
        public let averageMinutes: Int
        public let maximumMinutes: Int
    }

    /// Anzahl je Kategorie ab einem Zeitpunkt (Stufen für den SK-Verlauf).
    public struct TriagePoint: Equatable, Sendable {
        public let date: Date
        public let counts: [Sichtungskategorie: Int]

        public func count(_ triage: Sichtungskategorie) -> Int { counts[triage] ?? 0 }
    }

    public let start: Date
    public let end: Date?
    public let now: Date
    public let patientCount: Int
    public let firstPatientAt: Date?
    public let firstTriageAt: Date?
    /// Alle Patienten gesichtet (nur, wenn keiner mehr ungesichtet ist).
    public let allTriagedAt: Date?
    public let firstTransportAt: Date?
    /// Letzter Patient abtransportiert oder entlassen (nur, wenn keiner mehr wartet).
    public let lastPatientGoneAt: Date?
    public let waits: [Sichtungskategorie: Wait]
    public let triageSeries: [TriagePoint]
    public let milestones: [Milestone]

    public init(mission: Mission, patients allPatients: [Patient], journal: [JournalEntry], now: Date) {
        let patients = allPatients.active
        start = mission.startedAt
        end = mission.endedAt
        self.now = now
        patientCount = patients.count

        firstPatientAt = patients.map(\.metadata.createdAt).min()
        let triaged = patients.compactMap(\.firstTriagedAt)
        firstTriageAt = triaged.min()
        allTriagedAt = !patients.isEmpty && triaged.count == patients.count ? triaged.max() : nil
        let transports = patients.compactMap { patient -> Date? in
            if case .transported(let date) = patient.outcome { return date }
            return nil
        }
        firstTransportAt = transports.min()
        let outcomes = patients.compactMap { $0.outcome?.date }
        // Unverletzte und Verstorbene warten nicht auf Transport.
        let waiting = patients.filter { $0.outcome == nil && [.sk1, .sk2, .sk3, .ungesichtet].contains($0.triage) }
        lastPatientGoneAt = !outcomes.isEmpty && waiting.isEmpty ? outcomes.max() : nil

        var waits: [Sichtungskategorie: Wait] = [:]
        for category in [Sichtungskategorie.sk1, .sk2, .sk3] {
            let minutes = patients.compactMap { patient -> Int? in
                guard patient.triage == category, case .transported(let date) = patient.outcome else { return nil }
                return max(0, Int(date.timeIntervalSince(patient.metadata.createdAt) / 60))
            }
            guard !minutes.isEmpty else { continue }
            waits[category] = Wait(
                count: minutes.count,
                averageMinutes: Int((Double(minutes.reduce(0, +)) / Double(minutes.count)).rounded()),
                maximumMinutes: minutes.max() ?? 0
            )
        }
        self.waits = waits
        triageSeries = MissionMetrics.series(patients)
        milestones = MissionMetrics.milestones(
            mission: mission, journal: journal.active,
            firstPatient: firstPatientAt, firstTriage: firstTriageAt, allTriaged: allTriagedAt,
            firstTransport: firstTransportAt, lastGone: lastPatientGoneAt, patientCount: patients.count
        )
    }

    /// Minuten ab Einsatzbeginn (für „nach 12 min“).
    public func minutesFromStart(_ date: Date?) -> Int? {
        date.map { max(0, Int($0.timeIntervalSince(start) / 60)) }
    }

    // MARK: Verlauf

    private static func series(_ patients: [Patient]) -> [TriagePoint] {
        let dates = Set(patients.flatMap { patient in
            [patient.metadata.createdAt] + patient.effectiveTriageHistory.map(\.at)
        }).sorted()
        return dates.map { date in
            var counts: [Sichtungskategorie: Int] = [:]
            for patient in patients {
                if let triage = patient.triage(at: date) { counts[triage, default: 0] += 1 }
            }
            return TriagePoint(date: date, counts: counts)
        }
    }

    // MARK: Meilensteine

    private static func milestones(
        mission: Mission,
        journal: [JournalEntry],
        firstPatient: Date?, firstTriage: Date?, allTriaged: Date?,
        firstTransport: Date?, lastGone: Date?, patientCount: Int
    ) -> [Milestone] {
        var result = [Milestone(id: "start", kind: .start, date: mission.startedAt, title: "Einsatzbeginn", detail: mission.title)]
        if let firstPatient { result.append(Milestone(id: "firstPatient", kind: .firstPatient, date: firstPatient, title: "Erster Patient erfasst", detail: nil)) }
        if let firstTriage { result.append(Milestone(id: "firstTriage", kind: .firstTriage, date: firstTriage, title: "Erste Sichtung", detail: nil)) }
        if let allTriaged {
            result.append(Milestone(id: "allTriaged", kind: .allTriaged, date: allTriaged, title: "Alle gesichtet",
                                    detail: patientCount == 1 ? "1 Patient" : "\(patientCount) Patienten"))
        }
        if let firstTransport { result.append(Milestone(id: "firstTransport", kind: .firstTransport, date: firstTransport, title: "Erster Transport", detail: nil)) }
        for entry in journal {
            if entry.category == .situationReport {
                result.append(Milestone(id: "report-\(entry.id.rawValue.uuidString)", kind: .situationReport, date: entry.occurredAt, title: "Lagemeldung", detail: nil))
            } else if entry.category == .handover {
                result.append(Milestone(id: "handover-\(entry.id.rawValue.uuidString)", kind: .handover, date: entry.occurredAt, title: "Übergabe Einsatzleitung", detail: nil))
            } else if entry.origin == .automatic, entry.text.hasPrefix("Nachforderung an ILS:") {
                let detail = entry.text.dropFirst("Nachforderung an ILS:".count).trimmingCharacters(in: .whitespaces)
                result.append(Milestone(id: "request-\(entry.id.rawValue.uuidString)", kind: .request, date: entry.occurredAt, title: "Nachforderung", detail: detail))
            }
        }
        if let lastGone { result.append(Milestone(id: "lastGone", kind: .lastPatientGone, date: lastGone, title: "Letzter Patient versorgt", detail: "abtransportiert oder entlassen")) }
        if let ended = mission.endedAt { result.append(Milestone(id: "end", kind: .end, date: ended, title: "Einsatzende", detail: nil)) }
        return result.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }
}
