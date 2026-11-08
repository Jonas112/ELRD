import Foundation
import Testing
@testable import ELRDDomain

@Suite("Geführte Sichtung (Schritt 87)")
struct TriageGuideTests {
    private func run(_ algorithm: TriageAlgorithm, _ answers: [Bool], isChild: Bool = false) -> TriageSession {
        var session = TriageSession(algorithm: algorithm, isChild: isChild)
        for answer in answers { session.answer(answer) }
        return session
    }

    @Test func mstartUnremarkableWalkingIsSK3() throws {
        // Atmung ja, AF ok, Puls ja, befolgt ja, Stridor nein, Blutung nein, gehfähig ja
        let session = run(.mstart, [true, true, true, true, false, false, true])
        let suggestion = try #require(session.suggestion)
        #expect(suggestion.triage == .sk3)
        #expect(session.current == nil)
        #expect(suggestion.protocolText.hasPrefix("Sichtung nach mSTaRT: Atmung ja, AF 10–30 ja"))
    }

    @Test func mstartStopsAtFirstRedCriterion() throws {
        let session = run(.mstart, [true, false])
        #expect(session.suggestion?.triage == .sk1)
        #expect(session.suggestion?.reason.contains("Atemfrequenz") == true)
        // Weitere Antworten ändern nichts mehr.
        var after = session
        after.answer(true)
        #expect(after.answers.count == 2)
    }

    @Test func mstartBleedingAddsMeasure() throws {
        let suggestion = try #require(run(.mstart, [true, true, true, true, false, true]).suggestion)
        #expect(suggestion.triage == .sk1)
        #expect(suggestion.measures == ["Blutung stoppen"])
    }

    @Test func mstartNotWalkingIsSK2AndBackWorks() throws {
        var session = run(.mstart, [true, true, true, true, false, false, false])
        #expect(session.suggestion?.triage == .sk2)
        session.back()
        #expect(session.suggestion == nil)
        #expect(session.current?.id == "walking")
        session.answer(true)
        #expect(session.suggestion?.triage == .sk3)
    }

    @Test func priorABCDEThenWalking() throws {
        // Blutung nein, A–E nein, gehfähig nein → SK 2
        #expect(run(.prior, [false, false, false, false, false, false, false]).suggestion?.triage == .sk2)
        // C ja → SK 1
        let c = try #require(run(.prior, [false, false, false, true]).suggestion)
        #expect(c.triage == .sk1)
        #expect(c.reason.hasPrefix("C"))
        #expect(c.measures == ["Starke Blutung stoppen"])
    }

    @Test func priorAsksChildSignsOnlyForChildren() {
        #expect(TriageSession(algorithm: .prior).questions.count == 7)
        let child = TriageSession(algorithm: .prior, isChild: true)
        #expect(child.questions.count == 8)
        #expect(run(.prior, [false, false, false, false, false, false, true], isChild: true).suggestion?.triage == .sk1)
    }

    @Test func everyPathEndsWithASuggestion() {
        for algorithm in TriageAlgorithm.allCases {
            for isChild in [false, true] {
                var noSession = TriageSession(algorithm: algorithm, isChild: isChild)
                var yesSession = noSession
                for _ in noSession.questions {
                    noSession.answer(false)
                    yesSession.answer(true)
                }
                #expect(noSession.suggestion != nil)
                #expect(yesSession.suggestion != nil)
            }
        }
    }

    @Test func settingsKeepAlgorithmAndTolerateUnknownValue() throws {
        var settings = AppSettings()
        settings.triageAlgorithm = .prior
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.triageAlgorithm == .prior)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"triageAlgorithm":"neu"}"#.utf8))
        #expect(unknown.triageAlgorithm == .mstart)
    }
}
