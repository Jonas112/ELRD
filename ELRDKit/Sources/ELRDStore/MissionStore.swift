import Foundation
import Observation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Eine Aktion im Einsatz (Patient anlegen, Sichtung ändern, …).
///
/// Aktionen beschreiben eine Absicht und ändern nur den Entwurf. Dadurch kann der
/// `MissionStore` sie bei einem Konflikt (anderes Fenster hat gespeichert) auf dem
/// neuen Stand einfach noch einmal ausführen.
@MainActor
public protocol MissionCommand {
    associatedtype Output
    /// Ob die Aktion auch bei beendetem Einsatz erlaubt ist (z. B. Wiederöffnen).
    static var allowedOnClosedMission: Bool { get }
    func execute(_ draft: inout MissionDraft) throws -> Output
}

public extension MissionCommand {
    static var allowedOnClosedMission: Bool { false }
}

/// Uhr des Geräts für das Änderungsjournal. Eine Instanz pro App, geteilt von
/// allen geöffneten Einsätzen und Fenstern.
@MainActor
public final class DeviceClock {
    var clock: HybridLogicalClock

    public init(deviceID: DeviceID, repository: any EntityRepository) throws {
        clock = HybridLogicalClock(deviceID: deviceID, last: try repository.latestTimestamp(of: deviceID))
    }
}

/// Stand eines Einsatzes für die Oberfläche – und einziger Weg, ihn zu ändern.
@MainActor
@Observable
public final class MissionStore {
    public let missionID: MissionID
    public private(set) var state: MissionState

    @ObservationIgnored private let repository: any EntityRepository
    @ObservationIgnored private let session: SessionIdentity
    @ObservationIgnored private let deviceClock: DeviceClock
    @ObservationIgnored private let now: () -> Date

    /// Lädt einen vorhandenen Einsatz.
    public init(
        missionID: MissionID,
        repository: any EntityRepository,
        session: SessionIdentity,
        clock: DeviceClock,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.missionID = missionID
        self.repository = repository
        self.session = session
        self.deviceClock = clock
        self.now = now
        self.state = try Self.load(missionID, from: repository)
    }

    /// Legt einen neuen Einsatz an und öffnet ihn.
    public static func create(
        _ request: NewMissionRequest,
        repository: any EntityRepository,
        session: SessionIdentity,
        clock: DeviceClock,
        now: @escaping () -> Date = Date.init
    ) throws -> MissionStore {
        let context = CommandContext(session: session, now: now())
        let existing = try repository.missions(includeDeleted: true)
        var draft = MissionDraft(newMissionID: MissionID(), context: context)
        try request.build(into: &draft, existingMissions: existing)

        var hlc = clock.clock
        let changeSet = try draft.makeChangeSet(clock: &hlc)
        try repository.apply(changeSet)
        clock.clock = hlc
        return try MissionStore(missionID: draft.missionID, repository: repository, session: session, clock: clock, now: now)
    }

    /// Führt eine Aktion aus und speichert das Ergebnis.
    /// Hat ein anderes Fenster inzwischen gespeichert, wird neu geladen und die
    /// Aktion einmal auf dem neuen Stand wiederholt.
    @discardableResult
    public func perform<Command: MissionCommand>(_ command: Command) throws -> Command.Output {
        do {
            return try performOnce(command)
        } catch PersistenceError.staleWrite {
            try reload()
            return try performOnce(command)
        }
    }

    /// Lädt den Einsatz neu (z. B. nach Änderungen in einem anderen Fenster).
    public func reload() throws {
        state = try Self.load(missionID, from: repository)
    }

    /// Änderungsjournal dieses Einsatzes (für Protokoll-Details und Sync).
    public func changeEvents() throws -> [ChangeEvent] {
        try repository.changeEvents(in: missionID)
    }

    private func performOnce<Command: MissionCommand>(_ command: Command) throws -> Command.Output {
        if state.mission.isClosed && !Command.allowedOnClosedMission {
            throw CommandError.missionClosed
        }
        var draft = MissionDraft(state: state, context: CommandContext(session: session, now: now()))
        let output = try command.execute(&draft)

        var hlc = deviceClock.clock
        let changeSet = try draft.makeChangeSet(clock: &hlc)
        try repository.apply(changeSet)
        deviceClock.clock = hlc
        state = draft.makeState()
        return output
    }

    private static func load(_ missionID: MissionID, from repository: any EntityRepository) throws -> MissionState {
        guard let mission = try repository.entity(Mission.self, id: missionID) else {
            throw CommandError.notFound(.mission)
        }
        return MissionState(
            mission: mission,
            sections: try repository.entities(MissionSection.self, in: missionID, includeDeleted: true),
            units: try repository.entities(MissionUnit.self, in: missionID, includeDeleted: true),
            patients: try repository.entities(Patient.self, in: missionID, includeDeleted: true),
            journal: try repository.entities(JournalEntry.self, in: missionID, includeDeleted: true),
            messages: try repository.entities(MissionMessage.self, in: missionID, includeDeleted: true),
            logEntries: try repository.entities(MissionLogEntry.self, in: missionID, includeDeleted: true),
            mapObjects: try repository.entities(MapObject.self, in: missionID, includeDeleted: true)
        )
    }
}

// MARK: - Anzeigehilfen

public extension MissionState {
    var activeSections: [MissionSection] { MissionSection.sorted(sections) }
    var activeUnits: [MissionUnit] { MissionUnit.sorted(units) }
    var activePatients: [Patient] { Patient.sortedByNumber(patients) }
    var chronologicalJournal: [JournalEntry] { JournalEntry.chronological(journal) }
    var visibleLog: [MissionLogEntry] { MissionLogEntry.visible(logEntries) }
    var unreadMessageCount: Int { MissionMessage.unacknowledgedCount(in: messages) }
}
