import Foundation
import Observation
import ELRDDomain
import ELRDPersistence
import ELRDReports

/// Geräteeinstellungen lesen und schreiben (Dokument `appSettings`).
@MainActor
@Observable
public final class AppSettingsStore {
    private let repository: (any DocumentRepository)?
    public private(set) var settings: AppSettings

    public init(repository: (any DocumentRepository)?) {
        self.repository = repository
        settings = repository.flatMap { try? $0.document(AppSettings.self, key: .appSettings) } ?? AppSettings()
    }

    /// Ändert und speichert; bei Fehlern bleibt der alte Stand.
    func update(at date: Date = Date(), _ change: (inout AppSettings) -> Void) throws {
        var working = settings
        change(&working)
        guard working != settings else { return }
        try repository?.saveDocument(working, key: .appSettings, at: date)
        settings = working
    }

    /// Gestaltung für neue Berichte: Organisationsname und Banner aus den Einstellungen.
    func reportTheme(base: ReportTheme) -> ReportTheme {
        var theme = base
        if theme.bannerText.isEmpty { theme.bannerText = settings.organisationName }
        if theme.logo == nil { theme.logo = settings.bannerImage }
        return theme
    }
}

/// Berichtsvorlagen lesen und schreiben (Dokument `reportTemplates`).
@MainActor
@Observable
public final class ReportLibraryStore {
    private let repository: (any DocumentRepository)?
    public private(set) var library: ReportTemplateLibrary

    public init(repository: (any DocumentRepository)?) {
        self.repository = repository
        library = repository.flatMap { try? $0.document(ReportTemplateLibrary.self, key: .reportTemplates) } ?? ReportTemplateLibrary()
    }

    @discardableResult
    func save(_ template: ReportTemplate, at date: Date = Date()) throws -> ReportTemplate {
        var working = library
        let stored = working.save(template)
        try repository?.saveDocument(working, key: .reportTemplates, at: date)
        library = working
        return stored
    }

    func delete(_ id: UUID, at date: Date = Date()) throws {
        var working = library
        guard working.delete(id: id) else { return }
        try repository?.saveDocument(working, key: .reportTemplates, at: date)
        library = working
    }
}
