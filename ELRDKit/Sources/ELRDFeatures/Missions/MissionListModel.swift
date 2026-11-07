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
    @ObservationIgnored let now: () -> Date

    init(
        repository: any EntityRepository,
        session: SessionIdentity,
        clock: DeviceClock,
        entitlements: any EntitlementProvider,
        automaticSections: @escaping () -> [MasterSection] = { [] },
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.session = session
        self.clock = clock
        self.entitlements = entitlements
        self.automaticSections = automaticSections
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
            }
        )
    }

    /// Ohne Abo können Einsätze angesehen, aber nicht angelegt werden (E42).
    var canCreate: Bool { entitlements.isEnabled(.missionEditing) }

    var result: MissionListFilter.Result { filter.apply(to: missions, now: now()) }

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
}
