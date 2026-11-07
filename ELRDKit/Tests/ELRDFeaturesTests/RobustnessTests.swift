import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDFeatures
import ELRDStore
import ELRDAuth
import ELRDSync
import ELRDStammdaten

@Suite("Robustheit: Entwürfe und Fehlertexte")
@MainActor
struct RobustnessTests {
    // MARK: Entwürfe

    @Test func draftSetKeepsTextPerMissionAndField() {
        let first = MissionID()
        let second = MissionID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var set = TextDraftSet()
        let changed = set.set("RTW 2 angefordert", for: .journal, mission: first, at: start)
        #expect(changed)
        let unchanged = set.set("RTW 2 angefordert", for: .journal, mission: first, at: start)
        #expect(!unchanged, "gleicher Text → keine Änderung")
        set.set("Achtung Gasgeruch", for: .message, mission: first, at: start)
        #expect(set.text(.journal, mission: first) == "RTW 2 angefordert")
        #expect(set.text(.message, mission: first) == "Achtung Gasgeruch")
        #expect(set.text(.journal, mission: second).isEmpty, "anderer Einsatz hat keinen Entwurf")

        let cleared = set.set("  \n", for: .journal, mission: first, at: start)
        #expect(cleared, "nur Leerraum entfernt den Entwurf")
        #expect(set.text(.journal, mission: first).isEmpty)

        let tooOld = start.addingTimeInterval(TextDraftSet.maximumAge + 60)
        let pruned = set.prune(now: tooOld)
        #expect(pruned)
        #expect(set.isEmpty, "alte Entwürfe werden verworfen")
    }

    @Test func draftStoreSurvivesRestart() throws {
        let repository = InMemoryRepository()
        let mission = MissionID()
        let store = TextDraftStore(repository: repository, delay: .seconds(60))
        store.update("Lagemeldung an ILS: 12 Verletzte", for: .journal, mission: mission)
        #expect(try repository.document(TextDraftSet.self, key: .textDrafts) == nil, "erst nach kurzer Pause gesichert")
        store.flush()

        let restarted = TextDraftStore(repository: repository)
        #expect(restarted.text(.journal, mission: mission) == "Lagemeldung an ILS: 12 Verletzte")

        restarted.clear(.journal, mission: mission)
        let stored = try repository.document(TextDraftSet.self, key: .textDrafts)
        #expect(stored?.isEmpty == true, "Leeren wird sofort gesichert")
        #expect(TextDraftStore(repository: repository).text(.journal, mission: mission).isEmpty)
    }

    @Test func oldDraftsAreDroppedOnLoad() throws {
        let repository = InMemoryRepository()
        let mission = MissionID()
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        var set = TextDraftSet()
        set.set("alt", for: .message, mission: mission, at: then)
        try repository.saveDocument(set, key: .textDrafts, at: then)
        let later = then.addingTimeInterval(TextDraftSet.maximumAge * 2)
        let store = TextDraftStore(repository: repository, now: { later })
        #expect(store.text(.message, mission: mission).isEmpty)
        #expect(try repository.document(TextDraftSet.self, key: .textDrafts)?.isEmpty == true)
    }

    // MARK: Fehlertexte

    @Test func ownErrorsHaveGermanTexts() {
        let errors: [any Error] = [
            PersistenceError.staleWrite(entityID: UUID(), storedVersion: 2, newVersion: 1),
            PersistenceError.unsupportedPayloadVersion(9),
            PersistenceError.typeMismatch(expected: "Patient", found: "Mission"),
            BundledDataError.missingResource("Kliniken"),
            CSVError.missingColumn("Funkrufname"),
            CSVError.unreadableEncoding,
            SecureStoreError.keychain(-25300),
            PasswordHashError.randomGenerationFailed,
            HybridClockError.remoteClockTooFarAhead(remote: Date(), local: Date()),
            CommandError.missionClosed,
            AuthError.invalidCredentials,
        ]
        for error in errors {
            let text = ErrorText.message(for: error)
            #expect(!text.isEmpty)
            #expect(!text.contains("operation couldn"), "\(error)")
            #expect(!text.hasPrefix("Unerwarteter Fehler"), "\(error) braucht einen eigenen Text")
        }
    }

    @Test func systemErrorsGetHelpfulHints() {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        #expect(ErrorText.message(for: full).contains("Speicher des iPads ist voll"))
        let posixFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(ErrorText.message(for: posixFull).contains("voll"))
        let locked = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(ErrorText.message(for: locked).contains("gesperrt"))
    }

    @Test func unknownErrorsGetGenericTextWithCode() {
        enum Strange: Error { case boom }
        let text = ErrorText.message(for: Strange.boom)
        #expect(text.hasPrefix("Unerwarteter Fehler"))
        #expect(text.contains("nicht gespeichert"))
        let custom = NSError(domain: "SwiftData.SwiftDataError", code: 7)
        #expect(ErrorText.message(for: custom).hasSuffix("(SwiftDataError 7)"))
    }
}
