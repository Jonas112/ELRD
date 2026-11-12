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
    /// Übung (Schritt 88) und ggf. vorbereitete Lage.
    var isExercise = false
    var scenarioID: String?
    /// Lernpfad (Schritt 139).
    var isTutorial = false
    /// Übernahme aus Alamos FE2 (Schritt 140).
    var alarm: AlamosAlarm?
    var importsVehicles = false
    var importsPatients = false

    /// Vorbefüllt aus einem Einsatz aus Alamos FE2.
    static func importing(_ alarm: AlamosAlarm, settings: AlamosSettings) -> NewMissionForm {
        let data = alarm.data
        var form = NewMissionForm()
        form.alarm = alarm
        form.reason = data.title
        form.location = data.location?.addressLine ?? ""
        form.dispatchNumber = alarm.externalId
        form.importsVehicles = settings.importsVehicles && !data.callsigns.isEmpty
        form.importsPatients = settings.importsPatients && !data.patients.isEmpty
        // Echte Fahrzeuge statt Platzhalter: Stichwort nur ohne Fahrzeugübernahme.
        form.alarmstichwort = form.importsVehicles ? nil : data.alarmstichwort
        return form
    }

    /// Einsatzarten in der Reihenfolge der Auswahl (häufige zuerst).
    static let typeOrder: [MissionType] = MissionType.defaultOrder

    /// Baut die Anfrage; Standardabschnitte kommen aus den Stammdaten, dazu die der
    /// Vorlage der Einsatzart (Schritt 106).
    func request(automaticSections: [MasterSection], template: MissionTypeSetting? = nil, masterUnits: [MasterUnit] = []) -> NewMissionRequest {
        let sections = automaticSections.sorted { $0.sortIndex < $1.sortIndex }
        let merged = MissionTemplateSections.merge(
            master: sections.map(\.name),
            masterInitial: sections.first(where: \.isInitial)?.name,
            template: template?.type == type ? template : nil
        )
        let dispatch = Self.trimmed(dispatchNumber)
        var request = NewMissionRequest(
            reason: Self.trimmed(reason),
            type: type,
            location: Self.trimmed(location),
            dispatchNumber: dispatch.isEmpty ? nil : dispatch,
            sectionNames: merged.names,
            initialSectionName: merged.initial,
            alarmstichwort: alarmstichwort
        )
        request.isExercise = isExercise
        request.isTutorial = isTutorial
        request.scenario = isExercise ? scenarioID.flatMap(ExerciseScenario.scenario(id:)) : nil
        if let alarm {
            request.alarmImport = AlarmImport(
                alarm: alarm,
                includesVehicles: importsVehicles,
                includesPatients: importsPatients,
                masterUnits: masterUnits
            )
        }
        return request
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
    /// Fahrzeuge der Stammdaten (Übernahme aus Alamos FE2, Schritt 140).
    @ObservationIgnored let masterUnits: () -> [MasterUnit]
    @ObservationIgnored private let files: AttachmentFileStore?
    @ObservationIgnored let now: () -> Date

    init(
        repository: any EntityRepository,
        session: SessionIdentity,
        clock: DeviceClock,
        entitlements: any EntitlementProvider,
        automaticSections: @escaping () -> [MasterSection] = { [] },
        masterUnits: @escaping () -> [MasterUnit] = { [] },
        files: AttachmentFileStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.session = session
        self.clock = clock
        self.entitlements = entitlements
        self.automaticSections = automaticSections
        self.masterUnits = masterUnits
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
            masterUnits: {
                (try? repository.document(MasterDataSet.self, key: .masterData))?.units ?? []
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

    /// Statistik eines Jahres (`nil` = alle), Schritt 100.
    func statistics(year: Int?) -> MissionStatistics {
        MissionStatistics(summaries: missions, year: year)
    }

    /// Personensuche über alle Einsätze (Schritt 101).
    func searchPersons(_ query: String) -> [PersonSearchHit] {
        (try? PersonSearch.search(query, in: repository, now: now())) ?? []
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

    func create(_ form: NewMissionForm, template: MissionTypeSetting? = nil) throws -> MissionStore {
        let store = try MissionStore.create(
            form.request(automaticSections: automaticSections(), template: template, masterUnits: form.alarm == nil ? [] : masterUnits()),
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

    /// Schritt 102: fällige Einsätze anonymisieren (beim Öffnen der Liste).
    func anonymizeDue(afterDays days: Int) {
        let due = AnonymizationPolicy.due(missions, days: days, now: now())
        guard !due.isEmpty else { return }
        for id in due {
            _ = try? open(id).perform(AnonymizeMission(reason: "automatisch nach \(days) Tagen"))
        }
        reload()
    }

    func anonymize(_ missionID: MissionID) throws {
        try open(missionID).perform(AnonymizeMission(reason: "von Hand"))
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
