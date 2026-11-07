import Foundation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Ergebnis einer Übernahme fremder Ereignisse.
public struct RemoteImportResult: Equatable, Sendable {
    /// Neu übernommene Ereignisse.
    public var newEvents = 0
    /// Entitäten, deren Stand sich dadurch geändert hat.
    public var changedEntities = 0
    /// Einsätze mit neuen Ereignissen.
    public var missions: Set<MissionID> = []
    /// Ereignisse von Geräten, deren Uhr mehr als erlaubt vorgeht. Sie werden
    /// übernommen, verstellen aber die eigene Uhr nicht.
    public var clockWarnings = 0

    public init() {}
}

/// Übernimmt Ereignisse anderer Geräte (Schritt 53).
///
/// Für jede betroffene Entität wird aus **allen** bekannten Ereignissen (eigene
/// und fremde) der Stand neu zusammengeführt (`EntityHistory`). Dadurch ist das
/// Ergebnis unabhängig von der Reihenfolge, in der Geräte synchronisieren, und
/// doppelt empfangene Ereignisse ändern nichts.
@MainActor
public struct RemoteChangeImporter {
    private let repository: any EntityRepository
    private let clock: DeviceClock
    private let now: () -> Date

    public init(repository: any EntityRepository, clock: DeviceClock, now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.clock = clock
        self.now = now
    }

    /// Übernimmt die Ereignisse in einem Speichervorgang.
    @discardableResult
    public func importEvents(_ incoming: [ChangeEvent]) throws -> RemoteImportResult {
        var result = RemoteImportResult()
        guard !incoming.isEmpty else { return result }
        var changeSet = ChangeSet()
        var hlc = clock.clock

        for (missionID, events) in Dictionary(grouping: incoming, by: \.missionID) {
            let known = try repository.changeEvents(in: missionID)
            var seen = Set(known.map(\.id))
            var fresh: [ChangeEvent] = []
            for event in events where seen.insert(event.id).inserted {
                do {
                    try hlc.receive(event.timestamp, now: now())
                } catch {
                    result.clockWarnings += 1
                }
                fresh.append(event)
            }
            guard !fresh.isEmpty else { continue }

            // Einmal nach Entität gruppieren (große Einsätze: Tausende Ereignisse, Schritt 64).
            let byEntity = Dictionary(grouping: known + fresh, by: \.entityID)
            let touched = Set(fresh.map(\.entityID))
            for entityID in touched.sorted(by: { $0.uuidString < $1.uuidString }) {
                let history = EntityHistory(byEntity[entityID] ?? [])
                if try merge(history, into: &changeSet) { result.changedEntities += 1 }
            }
            for event in fresh { changeSet.record(event) }
            result.newEvents += fresh.count
            result.missions.insert(missionID)
        }

        try repository.apply(changeSet)
        clock.clock = hlc
        return result
    }

    private func merge(_ history: EntityHistory, into set: inout ChangeSet) throws -> Bool {
        switch history.entityType {
        case .mission: try merge(Mission.self, history, into: &set)
        case .section: try merge(MissionSection.self, history, into: &set)
        case .unit: try merge(MissionUnit.self, history, into: &set)
        case .patient: try merge(Patient.self, history, into: &set)
        case .journalEntry: try merge(JournalEntry.self, history, into: &set)
        case .message: try merge(MissionMessage.self, history, into: &set)
        case .logEntry: try merge(MissionLogEntry.self, history, into: &set)
        case .mapObject: try merge(MapObject.self, history, into: &set)
        case nil: false
        }
    }

    /// Schreibt den zusammengeführten Stand, wenn er sich vom gespeicherten unterscheidet.
    /// Ohne Anlegen (kommt später) bleibt die Entität vorerst unverändert.
    private func merge<Entity: SyncEntity>(_ type: Entity.Type, _ history: EntityHistory, into set: inout ChangeSet) throws -> Bool {
        guard let entityID = history.entityID, var merged = try history.entity(type) else { return false }
        let stored = try repository.entity(type, id: entityID)
        if let stored {
            // Die Version zählt lokal weiter, damit offene Fenster den neuen Stand erkennen.
            merged.metadata = merged.metadata.withVersion(stored.metadata.version)
            if merged == stored { return false }
            merged.metadata = merged.metadata.withVersion(stored.metadata.version + 1)
        }
        try set.upsert(merged)
        return true
    }
}
