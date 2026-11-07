import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDReports
@testable import ELRDEntitlements
@testable import ELRDFeatures
import ELRDStore

@Suite("Einstellungen, Vorlagen, Stammdatenverwaltung")
@MainActor
struct SettingsAndReportsTests {
    @Test func settingsAreStoredAndOldDocumentsStayReadable() throws {
        let repository = InMemoryRepository()
        let store = AppSettingsStore(repository: repository)
        try store.update { settings in
            settings.organisationName = "BRK Kreisverband Schweinfurt"
            settings.ilsEmail = "ils@beispiel.de"
            settings.unitTypeImages[UnitType.rtw.rawValue] = Data([1, 2, 3])
        }
        let reloaded = AppSettingsStore(repository: repository)
        #expect(reloaded.settings.organisationName == "BRK Kreisverband Schweinfurt")
        #expect(reloaded.settings.hasValidILSEmail)
        #expect(reloaded.settings.image(for: .rtw) == Data([1, 2, 3]))
        var theme = ReportTheme.standard
        theme = reloaded.reportTheme(base: theme)
        #expect(theme.bannerText == "BRK Kreisverband Schweinfurt", "Kopfzeile aus den Einstellungen")

        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"ilsEmail":"leitstelle@ils.de"}"#.utf8))
        #expect(old.ilsEmail == "leitstelle@ils.de")
        #expect(old.showsIVENA, "fehlende Felder → Standard")
        for bad in ["", "ils", "ils@", "@ils.de", "ils@de", "ils @ils.de", "ils@ils."] {
            var probe = AppSettings()
            probe.ilsEmail = bad
            #expect(!probe.hasValidILSEmail, "\(bad)")
        }
    }

    @Test func templateLibraryKeepsStandardsAndSavesCopies() throws {
        let repository = InMemoryRepository()
        let library = ReportLibraryStore(repository: repository)
        #expect(library.library.all.map(\.name) == ["Gesamtbericht", "Kurzbericht", "Klinikbericht"])
        var edited = ReportTemplateLibrary.short
        edited.name = "Kurz ILS"
        let stored = try library.save(edited)
        #expect(stored.id != ReportTemplateLibrary.shortID, "Standardvorlage wird als Kopie gespeichert")
        #expect(ReportLibraryStore(repository: repository).library.all.map(\.name) == ["Gesamtbericht", "Kurzbericht", "Klinikbericht", "Kurz ILS"])
        try library.delete(stored.id)
        #expect(library.library.custom.isEmpty)
        #expect(ReportTemplateLibrary.hospital.chapters.first { $0.kind == .patients }?.options.usesPatientSheets == true)
        #expect(ReportTemplateLibrary.short.chapters.first { $0.kind == .patients }?.options.showsPatientNames == false)
    }

    @Test func reportFileNameIsSafe() throws {
        let store = try PreviewData.makeStore()
        var mission = store.state.mission
        mission.reason = "VU B 19: Pkw/Lkw"
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-07T08:00:00Z"))
        let name = ReportFileName.make(template: "Gesamtbericht", mission: mission, date: date)
        #expect(name.hasPrefix("Gesamtbericht "))
        #expect(name.hasSuffix("2026-11-07.pdf"))
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(!name.contains("  "))
    }

    @Test func masterDataManagement() throws {
        let repository = InMemoryRepository()
        try repository.saveDocument(MasterDataSet(), key: .masterData, at: Date())
        let editor = MasterDataEditor(repository: repository)
        try editor.upsertUnit(MasterUnit(callsign: " RK SWFT 71/1 ", type: .rtw, crewCount: 2))
        #expect(editor.units.map(\.callsign) == ["RK SWFT 71/1"])
        #expect(throws: MasterDataEditError.duplicate("rk swft 71/1")) {
            try editor.upsertUnit(MasterUnit(callsign: "rk swft 71/1", type: .ktw))
        }
        var renamed = try #require(editor.units.first)
        renamed.callsign = "RK SWFT 71/2"
        try editor.upsertUnit(renamed)
        #expect(editor.units.map(\.callsign) == ["RK SWFT 71/2"], "geändert statt doppelt")
        try editor.removeUnit(renamed.id)
        #expect(editor.units.isEmpty)

        try editor.upsertHospital(MasterHospital(name: "Leopoldina", city: "Schweinfurt"))
        #expect(editor.hospitals.count == 1)
        #expect(throws: MasterDataEditError.emptyName) { try editor.upsertHospital(MasterHospital(name: "  ")) }

        try editor.save("Bereitstellungsraum")
        try editor.save("Patientenablage")
        let staging = try #require(editor.sections.first { $0.name == "Bereitstellungsraum" })
        try editor.setInitialSection(staging.id)
        #expect(editor.sections.filter(\.isInitial).map(\.name) == ["Bereitstellungsraum"])
        try editor.setIVENACatalog("ivena-untermain")
        #expect(MasterDataEditor(repository: repository).ivenaCatalogID == "ivena-untermain")
    }

    @Test func agreementTextsAreBundled() {
        #expect(Agreements.termsOfUse.contains("Benutzerlizenzvereinbarung"))
        #expect(Agreements.privacy.contains("Datenschutzerklärung"))
        var settings = AppSettings()
        #expect(!Agreements.isAccepted(settings))
        settings.acceptedAgreementVersion = Agreements.currentVersion
        #expect(Agreements.isAccepted(settings))
    }

    @Test func trialStartIsRememberedOnce() throws {
        let suite = "elrd.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = StoreKitEntitlements.storedTrial(defaults: defaults, now: Date(timeIntervalSince1970: 1000))
        let second = StoreKitEntitlements.storedTrial(defaults: defaults, now: Date(timeIntervalSince1970: 9000))
        #expect(first.startedAt == second.startedAt)
        #expect(first.length == TrialPeriod.defaultLength)
    }
}
