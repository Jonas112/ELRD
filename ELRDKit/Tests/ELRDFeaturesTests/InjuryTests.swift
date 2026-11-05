import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDPersistence
import ELRDStammdaten
import ELRDStore
import ELRDSync

@Suite("Verletzungen")
@MainActor
struct InjuryTests {
    static let catalog: [MasterInjury] = [
        MasterInjury(diagnosis: "Unterschenkel#", region: .unterschenkel),
        MasterInjury(diagnosis: "Unterschenkel# offen", region: .unterschenkel),
        MasterInjury(diagnosis: "SHT I", region: .kopf),
        MasterInjury(diagnosis: "stumpfes Thoraxtrauma", region: .thorax),
    ]

    @Test func suggestionsFilterByRegionAndSearch() {
        #expect(InjurySuggestions.matches(in: Self.catalog, region: .unterschenkel, search: "").count == 2)
        #expect(InjurySuggestions.matches(in: Self.catalog, region: nil, search: "offen").map(\.diagnosis) == ["Unterschenkel# offen"])
        #expect(InjurySuggestions.matches(in: Self.catalog, region: nil, search: "").first?.diagnosis == "SHT I", "von Kopf bis Fuß")
        #expect(InjurySuggestions.matches(in: Self.catalog, region: .thorax, search: "THORAX").count == 1)
    }

    @Test func customDiagnosisOnlyWhenNotInCatalog() {
        let matches = InjurySuggestions.matches(in: Self.catalog, region: nil, search: "sht i")
        #expect(!InjurySuggestions.offersCustom("sht i", in: matches))
        #expect(InjurySuggestions.offersCustom("Schnittwunde", in: []))
        #expect(!InjurySuggestions.offersCustom("   ", in: []))
    }

    @Test func injuryTakesRegionFromCatalogAndSideOnlyWhereItFits() {
        let leg = InjurySuggestions.injury(from: Self.catalog[0], text: "", region: nil, side: .rechts)
        #expect(leg.displayText == "Unterschenkel# Unterschenkel rechts")
        #expect(leg.masterInjuryID == Self.catalog[0].id)
        let head = InjurySuggestions.injury(from: Self.catalog[2], text: "", region: nil, side: .links)
        #expect(head.side == nil, "Kopf hat keine Seite")
        let custom = InjurySuggestions.injury(from: nil, text: "Schnittwunde", region: .hand, side: .links)
        #expect(custom.displayText == "Schnittwunde Hand links")
        #expect(custom.masterInjuryID == nil)
    }

    @Test func addAndRemoveAreSyncedElementwise() throws {
        let store = try PreviewData.makeStore()
        let patient = try #require(store.state.activePatients.first)
        let first = Injury(diagnosis: "Unterschenkel#", region: .unterschenkel, side: .rechts)
        let second = Injury(diagnosis: "SHT I", region: .kopf)
        try store.perform(AddInjury(patientID: patient.id, injury: first))
        try store.perform(AddInjury(patientID: patient.id, injury: second))
        try store.perform(AddInjury(patientID: patient.id, injury: first)) // doppelt: ohne Wirkung
        #expect(store.state.patients.first { $0.id == patient.id }?.injuries.count == 2)

        try store.perform(RemoveInjury(patientID: patient.id, injuryID: first.id))
        let remaining = store.state.patients.first { $0.id == patient.id }?.injuries
        #expect(remaining?.map(\.diagnosis) == ["SHT I"])

        // Im Journal einzeln, nicht als ganze Liste (für spätere Zusammenführung).
        let changes = try store.changeEvents().filter { $0.entityID == patient.id.rawValue }.flatMap(\.changes)
        #expect(changes.contains { if case .removeElement = $0 { true } else { false } })
        #expect(changes.contains { if case .upsertElement = $0 { true } else { false } })

        // Protokoll ohne Diagnose.
        #expect(store.state.visibleLog.last?.message == "Patient A-1: Verletzung entfernt")
        #expect(!store.state.visibleLog.contains { $0.message.contains("SHT") })

        #expect(throws: CommandError.invalid("Diagnose fehlt")) {
            try store.perform(AddInjury(patientID: patient.id, injury: Injury(diagnosis: "  ")))
        }
    }

    @Test func catalogsLoadDiagnosesAndIVENA() throws {
        let repository = InMemoryRepository()
        try repository.saveDocument(BundledMasterData.initialMasterData(), key: .masterData, at: Date())
        let catalogs = PatientCatalogs.load(from: repository)
        #expect(catalogs.injuries.count == 59)
        #expect((catalogs.rmi?.entries.count ?? 0) > 100)
    }
}
