import Foundation

// MARK: - Übungsleiter-Modus (Schritt 138)

/// Einlage, die die Übungsleitung während einer Übung einspielt – geplant (Minute ab
/// Beginn) oder sofort. Wirkung siehe `ReleaseExerciseInject`.
public struct ExerciseInject: Hashable, Codable, Sendable, Identifiable {
    /// Art als Text (tolerant: unbekannte Arten aus neueren Versionen werden zur Meldung, E95).
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Weitere Patienten (ungesichtet, Befunde in der Notiz).
        case patients
        /// Klinik nimmt nicht mehr auf (Kontingent 0).
        case hospitalFull
        /// Ein Patient verschlechtert sich (erwartete Kategorie steigt).
        case deterioration
        /// Einheit fällt aus (Meldung, ohne die Einheit zu ändern).
        case unitOut
        /// Freie Meldung (Presse, Angehörige, Gefahr …).
        case message

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .message
        }

        public var displayName: String {
            switch self {
            case .patients: "Weitere Patienten"
            case .hospitalFull: "Klinik voll"
            case .deterioration: "Verschlechterung"
            case .unitOut: "Einheit fällt aus"
            case .message: "Meldung"
            }
        }

        public var systemImage: String {
            switch self {
            case .patients: "person.2.badge.plus"
            case .hospitalFull: "cross.case.fill"
            case .deterioration: "waveform.path.ecg"
            case .unitOut: "exclamationmark.triangle.fill"
            case .message: "megaphone.fill"
            }
        }
    }

    /// Patient einer Einlage (Befund und erwartete Kategorie für die Auswertung).
    public struct InjectPatient: Hashable, Codable, Sendable {
        public var findings: String
        public var expected: Sichtungskategorie

        public init(findings: String, expected: Sichtungskategorie) {
            self.findings = findings
            self.expected = expected
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    /// Text der Meldung an die Einsatzleitung.
    public var text: String
    /// Minuten ab Einsatzbeginn; `nil` = nur von Hand.
    public var minute: Int?
    public var patients: [InjectPatient]?
    /// Klinik bei „Klinik voll“.
    public var hospitalName: String?
    /// Eingespielt um.
    public var releasedAt: Date?

    public init(id: UUID = UUID(), kind: Kind, title: String, text: String, minute: Int? = nil,
                patients: [InjectPatient]? = nil, hospitalName: String? = nil, releasedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.minute = minute
        self.patients = patients
        self.hospitalName = hospitalName
        self.releasedAt = releasedAt
    }

    public var isReleased: Bool { releasedAt != nil }

    /// Fällig, wenn geplant und die Minute erreicht ist.
    public func isDue(missionStart: Date, now: Date) -> Bool {
        guard !isReleased, let minute else { return false }
        return now >= missionStart.addingTimeInterval(TimeInterval(minute * 60))
    }

    /// Vorlagen für die Übungsleitung (Vorschlag von Claude, fachlich zu prüfen, E115).
    public static let templates: [ExerciseInject] = [
        ExerciseInject(kind: .patients, title: "Nachalarmierung: 2 weitere Verletzte",
                       text: "Polizei meldet zwei weitere Verletzte hinter dem Fahrzeug.", minute: 10,
                       patients: [
                           InjectPatient(findings: "Nicht gehfähig, AF 32/min, Radialispuls schwach, kaltschweißig.", expected: .sk1),
                           InjectPatient(findings: "Gehfähig, Platzwunde Stirn, AF 18/min.", expected: .sk3),
                       ]),
        ExerciseInject(kind: .hospitalFull, title: "Klinik meldet: keine Aufnahme mehr",
                       text: "Die Klinik meldet über die ILS: Schockraum belegt, keine weiteren Patienten.", minute: 15),
        ExerciseInject(kind: .deterioration, title: "Patient verschlechtert sich",
                       text: "Ein Patient der SK 2 trübt ein, AF steigt auf 30/min.", minute: 20),
        ExerciseInject(kind: .unitOut, title: "RTW fällt aus (Defekt)",
                       text: "Ein RTW meldet Defekt und fällt für den Transport aus.", minute: 25),
        ExerciseInject(kind: .message, title: "Presse an der Absperrung",
                       text: "Ein Reporter verlangt an der Absperrung Auskunft über die Verletzten.", minute: 12),
        ExerciseInject(kind: .message, title: "Angehörige suchen Kind",
                       text: "Eine Mutter sucht ihr Kind, das im Fahrzeug gewesen sein soll.", minute: 18),
        ExerciseInject(kind: .message, title: "Gefahr: Kraftstoff läuft aus",
                       text: "Feuerwehr meldet auslaufenden Kraftstoff, Patientenablage verlegen?", minute: 8),
    ]
}

/// Punkte einer Übung (Schritt 138): Sichtung, Tempo, Vollständigkeit, Lagemeldungen
/// und Reaktion auf Einlagen – höchstens 100.
public struct ExerciseScore: Equatable, Sendable {
    public struct Part: Equatable, Sendable, Identifiable {
        public let title: String
        public let points: Int
        public let maximum: Int
        public let detail: String
        public var id: String { title }
    }

    public let parts: [Part]
    public var total: Int { parts.map(\.points).reduce(0, +) }
    public var maximum: Int { parts.map(\.maximum).reduce(0, +) }

    /// Note in Worten.
    public var rating: String {
        let ratio = Double(total) / Double(max(maximum, 1))
        switch ratio {
        case 0.9...: return "sehr gut"
        case 0.75..<0.9: return "gut"
        case 0.5..<0.75: return "ausreichend"
        default: return "noch üben"
        }
    }

    public init?(mission: Mission, patients: [Patient], situationReports: Int, now: Date) {
        guard mission.isExerciseMission, let evaluation = ExerciseEvaluation(patients: patients) else { return nil }
        var parts: [Part] = []
        // Sichtung (40): Anteil wie erwartet.
        let accuracy = Double(evaluation.matching) / Double(max(evaluation.evaluated, 1))
        parts.append(Part(title: "Sichtung", points: Int((accuracy * 40).rounded()), maximum: 40,
                          detail: evaluation.summary))
        // Vollständigkeit (15): alle gesichtet.
        let triagedShare = Double(evaluation.evaluated - evaluation.notTriaged) / Double(max(evaluation.evaluated, 1))
        parts.append(Part(title: "Vollständig gesichtet", points: Int((triagedShare * 15).rounded()), maximum: 15,
                          detail: evaluation.notTriaged == 0 ? "alle gesichtet" : "\(evaluation.notTriaged) noch ungesichtet"))
        // Tempo (20): erste Sichtung nach Beginn.
        let metrics = MissionMetrics(mission: mission, patients: patients, journal: [], now: now)
        let firstMinutes = metrics.minutesFromStart(metrics.firstTriageAt)
        let speed: Int
        switch firstMinutes {
        case .some(let minutes) where minutes <= 5: speed = 20
        case .some(let minutes) where minutes <= 10: speed = 14
        case .some(let minutes) where minutes <= 15: speed = 8
        case .some: speed = 4
        case .none: speed = 0
        }
        parts.append(Part(title: "Tempo", points: speed, maximum: 20,
                          detail: firstMinutes.map { "erste Sichtung nach \($0) min" } ?? "noch keine Sichtung"))
        // Lagemeldungen (10): mindestens eine, ab 30 min Laufzeit zwei.
        let runtime = Int((mission.endedAt ?? now).timeIntervalSince(mission.startedAt) / 60)
        let needed = runtime >= 30 ? 2 : 1
        parts.append(Part(title: "Lagemeldungen", points: min(situationReports, needed) * 10 / needed, maximum: 10,
                          detail: situationReports == 1 ? "1 Lagemeldung" : "\(situationReports) Lagemeldungen"))
        // Einlagen (15): Patienten aus Einlagen gesichtet.
        let released = (mission.exerciseInjects ?? []).filter(\.isReleased)
        if !released.isEmpty {
            let injected = patients.active.filter { $0.notes.hasPrefix(ExerciseScore.injectMarker) }
            let handled = injected.filter { $0.triage != .ungesichtet }.count
            let share = injected.isEmpty ? 1 : Double(handled) / Double(injected.count)
            parts.append(Part(title: "Einlagen", points: Int((share * 15).rounded()), maximum: 15,
                              detail: "\(released.count) eingespielt" + (injected.isEmpty ? "" : ", \(handled) von \(injected.count) neuen Patienten gesichtet")))
        }
        self.parts = parts
    }

    /// Kennzeichen in der Notiz von Patienten aus Einlagen.
    public static let injectMarker = "Einlage: "
}
