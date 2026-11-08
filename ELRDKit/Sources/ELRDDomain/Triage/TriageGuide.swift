import Foundation

/// Sichtungsalgorithmus für die geführte Sichtung (Schritt 87, Einstellung).
///
/// Die Fragen sind als Daten hinterlegt und fachlich von Jonas zu prüfen (E104,
/// E107). Quellen: mSTaRT Erwachsene, Vorsichtung Trauma (BF München, V 4.1, 2018);
/// PRIOR® (Primäres Ranking zur Initialen Orientierung im Rettungsdienst).
public enum TriageAlgorithm: String, Codable, Sendable, CaseIterable, Identifiable, DisplayNamed {
    case mstart
    case prior

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mstart: "mSTaRT"
        case .prior: "PRIOR"
        }
    }

    public var detail: String {
        switch self {
        case .mstart: "Vorsichtung nach Vitalfunktionen (Atmung, Atemfrequenz, Radialispuls, Befolgen von Aufforderungen)"
        case .prior: "Priorisierung nach ABCDE, für Rettungsfachpersonal"
        }
    }
}

/// Was nach einer Antwort folgt.
public enum TriageStep: Equatable, Sendable {
    case next
    /// Ergebnis mit Begründung (steht im Protokoll und im Vorschlag).
    case result(Sichtungskategorie, reason: String)
}

/// Eine Ja/Nein-Frage des Algorithmus.
public struct TriageQuestion: Identifiable, Equatable, Sendable {
    public let id: String
    /// Kurzform fürs Protokoll, z. B. „Atmung“.
    public let short: String
    public let text: String
    public let hint: String?
    public let onYes: TriageStep
    public let onNo: TriageStep
    /// Sofortmaßnahme, wenn mit Ja beantwortet (z. B. „Blutung stoppen“).
    public let measureOnYes: String?
    public let measureOnNo: String?

    init(_ id: String, _ short: String, _ text: String, hint: String? = nil,
         yes: TriageStep = .next, no: TriageStep = .next,
         measureOnYes: String? = nil, measureOnNo: String? = nil) {
        self.id = id
        self.short = short
        self.text = text
        self.hint = hint
        onYes = yes
        onNo = no
        self.measureOnYes = measureOnYes
        self.measureOnNo = measureOnNo
    }
}

/// Vorschlag am Ende der geführten Sichtung – übernommen wird er per Tipp (E104).
public struct TriageSuggestion: Equatable, Sendable {
    public let algorithm: TriageAlgorithm
    public let triage: Sichtungskategorie
    public let reason: String
    public let measures: [String]
    /// Antworten in Kurzform, z. B. „Atmung ja, AF 10–30 nein“ (ohne Namen).
    public let answers: String

    /// Text fürs Protokoll.
    public var protocolText: String {
        "Sichtung nach \(algorithm.displayName): \(answers) → \(triage.shortName) (\(reason))"
    }
}

/// Ablauf einer geführten Sichtung: Fragen der Reihe nach, Zurück möglich.
public struct TriageSession: Equatable, Sendable {
    public let algorithm: TriageAlgorithm
    public let questions: [TriageQuestion]
    public private(set) var answers: [Bool] = []
    public private(set) var suggestion: TriageSuggestion?

    public init(algorithm: TriageAlgorithm, isChild: Bool = false) {
        self.algorithm = algorithm
        questions = TriageGuide.questions(for: algorithm, isChild: isChild)
    }

    /// Aktuelle Frage (`nil`, sobald ein Vorschlag feststeht).
    public var current: TriageQuestion? {
        guard suggestion == nil, answers.count < questions.count else { return nil }
        return questions[answers.count]
    }

    public var progress: Double {
        suggestion != nil ? 1 : Double(answers.count) / Double(max(questions.count, 1))
    }

    public mutating func answer(_ yes: Bool) {
        guard let question = current else { return }
        answers.append(yes)
        if case .result(let triage, let reason) = yes ? question.onYes : question.onNo {
            suggestion = makeSuggestion(triage, reason: reason)
        }
    }

    /// Letzte Antwort zurücknehmen.
    public mutating func back() {
        guard !answers.isEmpty else { return }
        answers.removeLast()
        suggestion = nil
    }

    private func makeSuggestion(_ triage: Sichtungskategorie, reason: String) -> TriageSuggestion {
        var measures: [String] = []
        var parts: [String] = []
        for (question, yes) in zip(questions, answers) {
            parts.append("\(question.short) \(yes ? "ja" : "nein")")
            if let measure = yes ? question.measureOnYes : question.measureOnNo { measures.append(measure) }
        }
        return TriageSuggestion(algorithm: algorithm, triage: triage, reason: reason, measures: measures, answers: parts.joined(separator: ", "))
    }
}

/// Fragen der Algorithmen.
public enum TriageGuide {
    public static func questions(for algorithm: TriageAlgorithm, isChild: Bool) -> [TriageQuestion] {
        switch algorithm {
        case .mstart: mstart
        case .prior: prior(isChild: isChild)
        }
    }

    /// mSTaRT Erwachsene (Vorsichtung Trauma).
    static let mstart: [TriageQuestion] = [
        TriageQuestion(
            "breathing", "Atmung", "Atmung vorhanden?",
            hint: "Falls nicht: Atemwege freimachen und erneut prüfen.",
            no: .result(.verstorben, reason: "keine Atmung nach Freimachen der Atemwege – Todesfeststellung durch Arzt"),
            measureOnNo: "Kennzeichnen, in Auffindesituation belassen"
        ),
        TriageQuestion(
            "rate", "AF 10–30", "Atemfrequenz zwischen 10 und 30 pro Minute?",
            no: .result(.sk1, reason: "Atemfrequenz unter 10 oder über 30/min")
        ),
        TriageQuestion(
            "pulse", "Radialispuls", "Radialispuls tastbar?",
            no: .result(.sk1, reason: "kein Radialispuls")
        ),
        TriageQuestion(
            "commands", "Befolgt Aufforderungen", "Befolgt einfache Aufforderungen?",
            hint: "z. B. „Drücken Sie meine Hand.“",
            no: .result(.sk1, reason: "befolgt keine einfachen Aufforderungen")
        ),
        TriageQuestion(
            "stridor", "Stridor", "Inhalationstrauma mit Stridor?",
            yes: .result(.sk1, reason: "Inhalationstrauma mit Stridor")
        ),
        TriageQuestion(
            "bleeding", "Spritzende Blutung", "Spritzende Blutung?",
            yes: .result(.sk1, reason: "spritzende Blutung"),
            measureOnYes: "Blutung stoppen"
        ),
        TriageQuestion(
            "walking", "Gehfähig", "Gehfähig?",
            hint: "Gehfähige zur Sammelstelle für Leichtverletzte (Nachsichtung).",
            yes: .result(.sk3, reason: "gehfähig, Vitalfunktionen unauffällig"),
            no: .result(.sk2, reason: "nicht gehfähig, Vitalfunktionen unauffällig")
        ),
    ]

    /// PRIOR: lebensbedrohliche Blutung, dann A–E, dann Gehfähigkeit.
    static func prior(isChild: Bool) -> [TriageQuestion] {
        var questions = [
            TriageQuestion(
                "bleeding", "Lebensbedrohliche Blutung", "Lebensbedrohliche Blutung?",
                yes: .result(.sk1, reason: "lebensbedrohliche Blutung – schnellstmöglicher Transport"),
                measureOnYes: "Blutung stoppen"
            ),
            TriageQuestion(
                "a", "A", "Bewusstlos oder (drohende) Verlegung der Atemwege?",
                yes: .result(.sk1, reason: "A – Atemweg"),
                measureOnYes: "Atemwege freimachen, Seitenlage"
            ),
            TriageQuestion(
                "b", "B", "Atemstörung?",
                hint: "Atemstillstand, deutlich gestörte Atemfrequenz, lautes krankhaftes Atemgeräusch",
                yes: .result(.sk1, reason: "B – Atmung"),
                measureOnYes: "Atemwege freimachen"
            ),
            TriageQuestion(
                "c", "C", "Kreislaufstörung?",
                hint: "kein Radialispuls, deutlich verzögerte Nagelbettfüllung, starke Blutung",
                yes: .result(.sk1, reason: "C – Kreislauf"),
                measureOnYes: "Starke Blutung stoppen"
            ),
            TriageQuestion(
                "d", "D", "Bewusstseinsstörung?",
                hint: "desorientiert bis somnolent, befolgt einfache Aufforderungen nicht",
                yes: .result(.sk1, reason: "D – Bewusstsein")
            ),
            TriageQuestion(
                "e", "E", "Starke Schmerzen am Körperstamm?",
                hint: "Thorax, Abdomen, Becken",
                yes: .result(.sk1, reason: "E – Schmerzen Körperstamm")
            ),
        ]
        if isChild {
            questions.append(TriageQuestion(
                "child", "Kind", "Zyanose, Nasenflügeln, Blässe, Lethargie oder punktförmige Hauteinblutungen?",
                yes: .result(.sk1, reason: "Zusatzzeichen beim Kind")
            ))
        }
        questions.append(TriageQuestion(
            "walking", "Gehfähig", "Kann ohne Hilfe gehen?",
            yes: .result(.sk3, reason: "A–E unauffällig, gehfähig"),
            no: .result(.sk2, reason: "A–E unauffällig, liegend bzw. nicht gehfähig")
        ))
        return questions
    }
}
