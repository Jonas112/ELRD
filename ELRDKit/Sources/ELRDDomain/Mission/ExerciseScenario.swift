import Foundation

/// Vorbereitete Übungslage (Schritt 88). Patienten kommen ungesichtet mit Befunden
/// in der Notiz – zum Sichten (gern mit der Sichtungshilfe, Schritt 87). Die
/// erwartete Kategorie dient nur der Auswertung nach der Übung.
///
/// Inhalte sind ein Vorschlag von Claude und fachlich von Jonas zu prüfen (E106).
public struct ExerciseScenario: Identifiable, Equatable, Sendable {
    public struct ScenarioPatient: Equatable, Sendable {
        /// Befunde für die Sichtung (ohne Lösung).
        public let findings: String
        /// Erwartete Kategorie nach mSTaRT/PRIOR (Auswertung).
        public let expected: Sichtungskategorie
        public let estimatedAge: Int?
        public let isChild: Bool

        init(_ findings: String, _ expected: Sichtungskategorie, age: Int? = nil, child: Bool = false) {
            self.findings = findings
            self.expected = expected
            estimatedAge = age
            isChild = child
        }
    }

    public let id: String
    public let name: String
    public let summary: String
    public let type: MissionType
    public let alarmstichwort: Alarmstichwort?
    public let reason: String
    public let location: String
    public let patients: [ScenarioPatient]

    public static func scenario(id: String) -> ExerciseScenario? {
        all.first { $0.id == id }
    }

    public static let all: [ExerciseScenario] = [traffic, bus, careHome, school]

    // Befunde jeweils in der Reihenfolge, die beide Algorithmen brauchen:
    // gehfähig, Atmung/AF, Puls/Rekap, Bewusstsein, Blutung, Schmerzen.

    static let traffic = ExerciseScenario(
        id: "vu-pkw-lkw",
        name: "VU Pkw gegen Lkw",
        summary: "5 Verletzte, eine Person eingeklemmt",
        type: .verkehrsunfall,
        alarmstichwort: nil,
        reason: "Übung: Pkw gegen Lkw, eine Person eingeklemmt",
        location: "Übungsgelände",
        patients: [
            ScenarioPatient("Fahrer Pkw, eingeklemmt. Atmet, AF 34/min, Radialispuls schwach tastbar, befolgt Aufforderungen, Schmerzen Becken.", .sk1, age: 45),
            ScenarioPatient("Beifahrerin. Nicht gehfähig, AF 18/min, Radialispuls tastbar, orientiert, offene Unterschenkelfraktur, keine spritzende Blutung.", .sk2, age: 40),
            ScenarioPatient("Kind auf dem Rücksitz. Läuft weinend umher, AF 24/min, Schürfwunden Stirn.", .sk3, age: 8, child: true),
            ScenarioPatient("Lkw-Fahrer. Gehfähig, AF 16/min, Prellung Thorax, Schmerzen bei Atmung gering.", .sk3, age: 52),
            ScenarioPatient("Ersthelfer. Gehfähig, Schnittverletzung Hand, blutet leicht.", .sk3, age: 30),
        ]
    )

    static let bus = ExerciseScenario(
        id: "bus",
        name: "Reisebus umgestürzt",
        summary: "12 Verletzte, MANV",
        type: .verkehrsunfall,
        alarmstichwort: nil,
        reason: "Übung: Reisebus auf die Seite gestürzt",
        location: "Übungsgelände",
        patients: [
            ScenarioPatient("Liegt neben dem Bus. Keine Atmung, auch nach Freimachen der Atemwege nicht.", .verstorben, age: 70),
            ScenarioPatient("Atmet, AF 8/min, reagiert nicht auf Ansprache.", .sk1, age: 65),
            ScenarioPatient("Atmet, AF 22/min, kein Radialispuls tastbar, blass, kaltschweißig.", .sk1, age: 58),
            ScenarioPatient("Atmet, AF 20/min, Radialispuls tastbar, spritzende Blutung Oberarm.", .sk1, age: 34),
            ScenarioPatient("Atmet, AF 26/min, Radialispuls tastbar, verwirrt, befolgt keine Aufforderungen.", .sk1, age: 77),
            ScenarioPatient("Nicht gehfähig, AF 18/min, Radialispuls tastbar, orientiert, Oberschenkel deformiert.", .sk2, age: 49),
            ScenarioPatient("Nicht gehfähig, AF 20/min, Radialispuls tastbar, orientiert, Unterarmfraktur.", .sk2, age: 62),
            ScenarioPatient("Nicht gehfähig, AF 16/min, Radialispuls tastbar, orientiert, Sprunggelenk geschwollen.", .sk2, age: 23),
            ScenarioPatient("Gehfähig, AF 18/min, Platzwunde Kopf, orientiert.", .sk3, age: 19),
            ScenarioPatient("Gehfähig, AF 16/min, Prellungen, orientiert.", .sk3, age: 44),
            ScenarioPatient("Gehfähig, AF 20/min, Schürfwunden, aufgeregt.", .sk3, age: 15, child: true),
            ScenarioPatient("Busfahrer. Gehfähig, AF 14/min, unverletzt, psychisch belastet.", .sk3, age: 55),
        ]
    )

    static let careHome = ExerciseScenario(
        id: "pflegeheim",
        name: "Brand im Pflegeheim",
        summary: "8 Betroffene, Rauchgas",
        type: .brand,
        alarmstichwort: nil,
        reason: "Übung: Zimmerbrand im Pflegeheim, Bewohner evakuiert",
        location: "Übungsgelände",
        patients: [
            ScenarioPatient("Bewohner aus dem Brandzimmer. Atmet, AF 32/min, Stridor, Ruß im Gesicht.", .sk1, age: 84),
            ScenarioPatient("Bewohnerin. Atmet, AF 24/min, Radialispuls tastbar, desorientiert (bekannte Demenz?), befolgt keine Aufforderungen.", .sk1, age: 90),
            ScenarioPatient("Pflegekraft. Gehfähig, hustet, AF 22/min, orientiert.", .sk3, age: 36),
            ScenarioPatient("Bewohner, bettlägerig. AF 20/min, Radialispuls tastbar, orientiert, hustet.", .sk2, age: 81),
            ScenarioPatient("Bewohnerin im Rollstuhl. AF 18/min, Radialispuls tastbar, orientiert.", .sk2, age: 86),
            ScenarioPatient("Bewohner. Gehfähig, AF 16/min, orientiert, keine Beschwerden.", .sk3, age: 79),
            ScenarioPatient("Bewohnerin. Gehfähig, AF 18/min, ängstlich, keine Verletzung.", .sk3, age: 75),
            ScenarioPatient("Hausmeister. Gehfähig, Verbrennung Handrücken, AF 16/min.", .sk3, age: 58),
        ]
    )

    static let school = ExerciseScenario(
        id: "reizgas-schule",
        name: "Reizgas in einer Schule",
        summary: "10 Betroffene, Atemwegsreizung",
        type: .mehrfachErkrankte,
        alarmstichwort: nil,
        reason: "Übung: Reizgas im Klassenzimmer, mehrere Schüler mit Atemnot",
        location: "Übungsgelände",
        patients: [
            ScenarioPatient("Schülerin. Atmet, AF 36/min, Lippen bläulich, sitzt nach vorne gebeugt.", .sk1, age: 14, child: true),
            ScenarioPatient("Schüler. Atmet, AF 28/min, Radialispuls tastbar, Nasenflügeln, lethargisch, befolgt keine Aufforderungen.", .sk1, age: 12, child: true),
            ScenarioPatient("Lehrerin. Nicht gehfähig (Schwindel), AF 22/min, Radialispuls tastbar, orientiert.", .sk2, age: 41),
            ScenarioPatient("Schüler. Gehfähig, Augenbrennen, hustet, AF 20/min.", .sk3, age: 13, child: true),
            ScenarioPatient("Schülerin. Gehfähig, Augenbrennen, AF 18/min.", .sk3, age: 13, child: true),
            ScenarioPatient("Schüler. Gehfähig, Übelkeit, AF 18/min.", .sk3, age: 14, child: true),
            ScenarioPatient("Schülerin. Gehfähig, hustet, AF 22/min.", .sk3, age: 12, child: true),
            ScenarioPatient("Schüler. Gehfähig, keine Beschwerden, aufgeregt.", .sk3, age: 14, child: true),
            ScenarioPatient("Hausmeister. Gehfähig, Augenbrennen, AF 16/min.", .sk3, age: 60),
            ScenarioPatient("Schülerin. Nicht gehfähig (Kreislauf), AF 20/min, Radialispuls tastbar, orientiert, blass.", .sk2, age: 13, child: true),
        ]
    )
}

/// Auswertung einer Übung: Sichtung im Vergleich zur erwarteten Kategorie.
public struct ExerciseEvaluation: Equatable, Sendable {
    public struct Deviation: Equatable, Sendable {
        public let number: String
        public let expected: Sichtungskategorie
        public let actual: Sichtungskategorie
    }

    public let evaluated: Int
    public let matching: Int
    public let notTriaged: Int
    public let deviations: [Deviation]

    /// `nil`, wenn keine Patienten mit erwarteter Kategorie vorhanden sind.
    public init?(patients: [Patient]) {
        let scored = Patient.sortedByNumber(patients.active).filter { $0.expectedTriage != nil }
        guard !scored.isEmpty else { return nil }
        evaluated = scored.count
        notTriaged = scored.filter { $0.triage == .ungesichtet }.count
        let triaged = scored.filter { $0.triage != .ungesichtet }
        matching = triaged.filter { $0.triage == $0.expectedTriage }.count
        deviations = triaged.compactMap { patient in
            guard let expected = patient.expectedTriage, expected != patient.triage else { return nil }
            return Deviation(number: patient.number.description, expected: expected, actual: patient.triage)
        }
    }

    /// „7 von 10 wie erwartet · 2 abweichend · 1 noch ungesichtet“
    public var summary: String {
        var parts = ["\(matching) von \(evaluated) wie erwartet"]
        if !deviations.isEmpty { parts.append("\(deviations.count) abweichend") }
        if notTriaged > 0 { parts.append("\(notTriaged) noch ungesichtet") }
        return parts.joined(separator: " · ")
    }
}
