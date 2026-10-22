import Foundation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Wer arbeitet auf welchem Gerät.
public struct SessionIdentity: Hashable, Sendable {
    public let userID: UserID?
    /// Name für automatische Texte („Einsatz wurde durch … beendet“).
    public let displayName: String
    public let device: DeviceIdentity

    public init(userID: UserID?, displayName: String, device: DeviceIdentity) {
        self.userID = userID
        self.displayName = displayName
        self.device = device
    }
}

/// Rahmen einer einzelnen Aktion: wer, auf welchem Gerät, zu welchem Zeitpunkt.
/// Alle Änderungen einer Aktion tragen denselben Zeitpunkt.
public struct CommandContext: Sendable {
    public let session: SessionIdentity
    public let now: Date

    public init(session: SessionIdentity, now: Date) {
        self.session = session
        self.now = now
    }

    public func newMetadata() -> EntityMetadata { .new(by: session.userID, at: now) }
    public var numberPrefix: String { session.device.numberPrefix }
}

/// Fehler bei der Ausführung von Aktionen.
public enum CommandError: Error, Equatable, Sendable {
    case missionClosed
    case missionAlreadyClosed
    case missionNotClosed
    case notFound(SyncEntityType)
    case duplicate(UUID)
    case invalid(String)
}

/// Vollständiger Stand eines Einsatzes (einschließlich gelöschter Einträge,
/// damit Nummern nicht doppelt vergeben werden).
public struct MissionState: Equatable, Sendable {
    public var mission: Mission
    public var sections: [MissionSection]
    public var units: [MissionUnit]
    public var patients: [Patient]
    public var journal: [JournalEntry]
    public var messages: [MissionMessage]
    public var logEntries: [MissionLogEntry]
    public var mapObjects: [MapObject]
}

/// Arbeitskopie eines Einsatzes für genau eine Aktion.
///
/// Aktionen ändern nur den Entwurf. Erst `MissionStore` speichert ihn – samt
/// Journal und Protokoll – in einem Schritt. Wirft die Aktion einen Fehler,
/// wird der Entwurf verworfen und nichts ändert sich.
public struct MissionDraft: Sendable {
    public let context: CommandContext
    public let missionID: MissionID

    var missions: EntityCollection<Mission>
    var sections: EntityCollection<MissionSection>
    var units: EntityCollection<MissionUnit>
    var patients: EntityCollection<Patient>
    var journal: EntityCollection<JournalEntry>
    var messages: EntityCollection<MissionMessage>
    var logEntries: EntityCollection<MissionLogEntry>
    var mapObjects: EntityCollection<MapObject>

    init(state: MissionState, context: CommandContext) {
        self.context = context
        missionID = state.mission.id
        missions = EntityCollection([state.mission])
        sections = EntityCollection(state.sections)
        units = EntityCollection(state.units)
        patients = EntityCollection(state.patients)
        journal = EntityCollection(state.journal)
        messages = EntityCollection(state.messages)
        logEntries = EntityCollection(state.logEntries)
        mapObjects = EntityCollection(state.mapObjects)
    }

    /// Leerer Entwurf für einen neuen Einsatz.
    init(newMissionID: MissionID, context: CommandContext) {
        self.context = context
        missionID = newMissionID
        missions = EntityCollection([])
        sections = EntityCollection([])
        units = EntityCollection([])
        patients = EntityCollection([])
        journal = EntityCollection([])
        messages = EntityCollection([])
        logEntries = EntityCollection([])
        mapObjects = EntityCollection([])
    }

    // MARK: Lesen

    /// Der Einsatz dieses Entwurfs.
    public var mission: Mission {
        // Ein Entwurf entsteht immer aus einem geladenen Einsatz oder legt ihn als Erstes an.
        guard let mission = missions.get(missionID.rawValue) else {
            preconditionFailure("MissionDraft ohne Einsatz")
        }
        return mission
    }

    public func get<Entity: SyncEntity, Tag>(_ type: Entity.Type, id: EntityID<Tag>) -> Entity? {
        self[keyPath: path(for: type)].get(id.rawValue)
    }

    /// Alle Entitäten einer Art, einschließlich gelöschter.
    public func all<Entity: SyncEntity>(_ type: Entity.Type) -> [Entity] {
        self[keyPath: path(for: type)].all
    }

    public func active<Entity: SyncEntity>(_ type: Entity.Type) -> [Entity] {
        self[keyPath: path(for: type)].active
    }

    // MARK: Ändern

    public mutating func insert<Entity: SyncEntity>(_ entity: Entity) throws {
        guard entity.missionID == missionID else { throw CommandError.invalid("Falscher Einsatz") }
        let path = path(for: Entity.self)
        try self[keyPath: path].insert(entity)
    }

    @discardableResult
    public mutating func update<Entity: SyncEntity, Tag>(
        _ type: Entity.Type,
        id: EntityID<Tag>,
        _ transform: (inout Entity) throws -> Void
    ) throws -> Entity {
        let context = context
        let path = path(for: type)
        return try self[keyPath: path].update(id.rawValue, context: context, transform)
    }

    @discardableResult
    public mutating func updateMission(_ transform: (inout Mission) throws -> Void) throws -> Mission {
        try update(Mission.self, id: missionID, transform)
    }

    public mutating func delete<Entity: SyncEntity, Tag>(_ type: Entity.Type, id: EntityID<Tag>) throws {
        let context = context
        let path = path(for: type)
        try self[keyPath: path].delete(id.rawValue, context: context)
    }

    // MARK: Protokoll und Tagebuch

    /// Schreibt einen Protokolleintrag. Patienten nur über ihre Nummer nennen (E25).
    public mutating func log(
        _ category: LogCategory,
        _ message: String,
        subject: LogSubject? = nil,
        level: LogLevel = .user
    ) {
        let entry = MissionLogEntry(
            missionID: missionID,
            metadata: context.newMetadata(),
            timestamp: context.now,
            category: category,
            level: level,
            message: message,
            subject: subject
        )
        // Neue UUID – ein Konflikt ist ausgeschlossen.
        try? logEntries.insert(entry)
    }

    /// Legt einen Tagebucheintrag mit der nächsten Nummer dieses Geräts an.
    @discardableResult
    public mutating func addJournalEntry(
        text: String,
        origin: JournalOrigin,
        occurredAt: Date? = nil,
        attachments: [FileAttachment] = []
    ) throws -> JournalEntry {
        let entry = JournalEntry(
            missionID: missionID,
            metadata: context.newMetadata(),
            number: JournalEntry.nextNumber(prefix: context.numberPrefix, existing: journal.all),
            occurredAt: occurredAt ?? context.now,
            text: text,
            origin: origin,
            attachments: attachments
        )
        guard !entry.isEmpty else { throw CommandError.invalid("Leerer Tagebucheintrag") }
        try journal.insert(entry)
        return entry
    }

    // MARK: Abschluss (MissionStore)

    /// Erzeugt Speicherpaket mit allen Änderungen und Journaleinträgen.
    func makeChangeSet(clock: inout HybridLogicalClock) throws -> ChangeSet {
        var set = ChangeSet()
        // Einsatz zuerst, damit sein Anlegen im Journal vor allem anderen steht.
        try collect(missions, into: &set, clock: &clock)
        try collect(sections, into: &set, clock: &clock)
        try collect(units, into: &set, clock: &clock)
        try collect(patients, into: &set, clock: &clock)
        try collect(journal, into: &set, clock: &clock)
        try collect(messages, into: &set, clock: &clock)
        try collect(mapObjects, into: &set, clock: &clock)
        try collect(logEntries, into: &set, clock: &clock)
        return set
    }

    private func collect<Entity: SyncEntity>(
        _ collection: EntityCollection<Entity>,
        into set: inout ChangeSet,
        clock: inout HybridLogicalClock
    ) throws {
        for (old, new) in collection.changes() {
            try set.upsert(new)
            let event = try ChangeRecorder.event(
                old: old, new: new, clock: &clock, author: context.session.userID, now: context.now
            )
            if let event { set.record(event) }
        }
    }

    /// Stand nach der Aktion.
    func makeState() -> MissionState {
        MissionState(
            mission: mission,
            sections: sections.all,
            units: units.all,
            patients: patients.all,
            journal: journal.all,
            messages: messages.all,
            logEntries: logEntries.all,
            mapObjects: mapObjects.all
        )
    }

    /// Ordnet jeder Entitätsart ihre Sammlung zu.
    private func path<Entity: SyncEntity>(for type: Entity.Type) -> WritableKeyPath<MissionDraft, EntityCollection<Entity>> {
        let path: AnyKeyPath = switch Entity.syncEntityType {
        case .mission: \MissionDraft.missions
        case .section: \MissionDraft.sections
        case .unit: \MissionDraft.units
        case .patient: \MissionDraft.patients
        case .journalEntry: \MissionDraft.journal
        case .message: \MissionDraft.messages
        case .logEntry: \MissionDraft.logEntries
        case .mapObject: \MissionDraft.mapObjects
        }
        // Die Zuordnung ist über `syncEntityType` eindeutig; ein Fehlschlag wäre ein Programmierfehler.
        guard let typed = path as? WritableKeyPath<MissionDraft, EntityCollection<Entity>> else {
            preconditionFailure("Keine Sammlung für \(Entity.self)")
        }
        return typed
    }
}
