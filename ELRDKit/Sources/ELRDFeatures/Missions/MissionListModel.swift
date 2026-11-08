import Foundation
import Observation
import ELRDDomain
import ELRDPersistence
import ELRDAuth
import ELRDEntitlements
import ELRDStore

/// Eingaben für „Neuer Einsatz“ – bewusst nur das Nötigste, alles andere später.
struct NewMissionForm: Equatable {
    var alarmstichwort: Alarmstichwort?
    var type: MissionType?
    var location = ""
    /// Meldebild / Einsatzgrund; wird zum Titel des Einsatzes.
    var reason = ""
    /// Einsatznummer der Leitstelle als Freitext (E47).
    var dispatchNumber = ""

    /// Einsatzarten in der Reihenfolge der Auswahl (häufige zuerst).
    static let typeOrder: [MissionType] = [
        .verkehrsunfall, .brand, .bma, .mehrfachErkrankte, .gefahrgut,
        .vermisstensuche, .polizeiSonderlage, .bergrettung, .wasserrettung, .sonstiges,
    ]

    /// Baut die Anfrage; Standardabschnitte kommen aus den Stammdaten.
    func request(automaticSections: [MasterSection]) -> NewMissionRequest {
        let sections = automaticSections.sorted { $0.sortIndex < $1.sortIndex }
        let dispatch = Self.trimmed(dispatchNumber)
        return NewMissionRequest(
            reason: Self.trimmed(reason),
            type: type,
            location: Self.trimmed(location),
            dispatchNumber: dispatch.isEmpty ? nil : dispatch,
            sectionNames: sections.map(\.name),
            initialSectionName: sections.first(where: \.isInitial)?.name,
            alarmstichwort: alarmstichwort
        )
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MissionType {
    /// Kurze Beschriftung für Auswahl-Chips.
    var chipLabel: String {
        switch self {
        case .verkehrsunfall: "VU"
        case .bma: "BMA"
        default: displayName
        }
    }
}

/// Einsatzliste: lesen, anlegen, öffnen, löschen.
///
/// Geschrieben wird ausschließlich über `MissionStore` und dessen Commands.
@MainActor
@Observable
final class MissionListModel {
    private(set) var missions: [MissionSummary] = []
    /// Gelöschte Einsätze (wiederherstellbar, Schritt 54).
    private(set) var deletedMissions: [MissionSummary] = []
    var filter = MissionListFilter()
    private(set) var loadError: String?

    let session: SessionIdentity
    @ObservationIgnored private let repository: any EntityRepository
    @ObservationIgnored private let clock: DeviceClock
    @ObservationIgnored private let entitlements: any EntitlementProvider
    @ObservationIgnored private let automaticSections: () -> [MasterSection]
    @ObservationIgnored private let files: AttachmentFileStore?
    @ObservationIgnored let now: () -> Date

    init(
        repository: any EntityRepository,
        session: SessionIdentity,
        clock: DeviceClock,
        entitlements: any EntitlementProvider,
        automaticSections: @escaping () -> [MasterSection] = { [] },
        files: AttachmentFileStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.session = session
        self.clock = clock
        self.entitlements = entitlements
        self.automaticSections = automaticSections
        self.files = files
        self.now = now
        reload()
    }

    convenience init(environment: AppEnvironment, user: UserAccount) {
        let repository = environment.repository
        self.init(
            repository: repository,
            session: SessionIdentity(userID: user.id, displayName: user.displayName, device: environment.device),
            clock: environment.deviceClock,
            entitlements: environment.entitlements,
            automaticSections: {
                (try? repository.document(MasterDataSet.self, key: .masterData))?.automaticSections ?? []
            },
            files: environment.attachments
        )
    }

    /// Ohne Abo können Einsätze angesehen, aber nicht angelegt werden (E42).
    var canCreate: Bool { entitlements.isEnabled(.missionEditing) }

    var result: MissionListFilter.Result { filter.apply(to: missions, now: now()) }

    /// Fehler von außen anzeigen (z. B. Einladung konnte nicht angenommen werden).
    func reportError(_ message: String) {
        loadError = message
    }

    func clearError() {
        loadError = nil
    }

    func reload() {
        do {
            missions = try MissionOverview.load(from: repository)
            deletedMissions = try MissionOverview.loadDeleted(from: repository)
            loadError = nil
        } catch {
            loadError = ErrorText.message(for: error)
        }
    }

    func create(_ form: NewMissionForm) throws -> MissionStore {
        let store = try MissionStore.create(
            form.request(automaticSections: automaticSections()),
            repository: repository,
            session: session,
            clock: clock,
            entitlements: entitlements,
            now: now
        )
        reload()
        return store
    }

    func open(_ missionID: MissionID) throws -> MissionStore {
        try MissionStore(
            missionID: missionID,
            repository: repository,
            session: session,
            clock: clock,
            entitlements: entitlements,
            now: now
        )
    }

    func delete(_ missionID: MissionID) throws {
        try open(missionID).perform(DeleteMission())
        reload()
    }

    func restore(_ missionID: MissionID) throws {
        try open(missionID).perform(RestoreMission())
        reload()
    }

    // MARK: Einsatz als Datei (Schritt 63)

    /// Schreibt den Einsatz als Datei in einen temporären Ordner (zum Teilen).
    func exportFile(_ missionID: MissionID) throws -> URL {
        let archive = try MissionArchive.make(mission: missionID, repository: repository, files: files, now: now())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(archive.suggestedFileName)
        try archive.encoded().write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Öffnet eine Einsatzdatei (Teilen, AirDrop, Dateien-App).
    @discardableResult
    func importFile(_ url: URL) throws -> MissionArchiveImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let archive = try MissionArchive.decode(Data(contentsOf: url))
        let result = try archive.importInto(repository: repository, clock: clock, files: files)
        reload()
        return result
    }

    /// Einsatz von einem iPad in der Nähe übernehmen (Schritt 66).
    func makeNearbyExchange(_ missionID: MissionID) -> NearbyExchange {
        NearbyExchange(missionID: missionID, repository: repository, clock: clock, files: files)
    }

    /// Entfernt einen gelöschten Einsatz endgültig (Datenschutz).
    func purge(_ missionID: MissionID) throws {
        try MissionPurge.purge(missionID, repository: repository, files: files)
        reload()
    }
}
