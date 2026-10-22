import Foundation
import ELRDDomain
import ELRDSync

/// `EntityRepository` im Arbeitsspeicher – für SwiftUI-Vorschauen und Tests.
///
/// Verhält sich wie `SwiftDataRepository` (gleiche Vertragstests), speichert aber
/// nichts dauerhaft. Nutzt dieselbe JSON-Umwandlung über `EntitySnapshot`.
@MainActor
public final class InMemoryRepository: EntityRepository {
    private var snapshots: [UUID: EntitySnapshot] = [:]
    private var events: [UUID: ChangeEvent] = [:]

    /// Für Tests: lässt das nächste `apply` nach dem Prüfen fehlschlagen.
    public var failNextApply = false

    public init() {}

    public func apply(_ changeSet: ChangeSet) throws {
        guard !changeSet.isEmpty else { return }
        // Erst alles prüfen, dann schreiben – damit „ganz oder gar nicht“ gilt.
        for snapshot in changeSet.snapshots {
            if let stored = snapshots[snapshot.entityID] {
                guard stored.entityType == snapshot.entityType else {
                    throw PersistenceError.typeMismatch(expected: snapshot.entityType.rawValue, found: stored.entityType.rawValue)
                }
                try snapshot.checkCanReplace(storedVersion: stored.version, storedPayload: stored.payload)
            }
        }
        if failNextApply {
            failNextApply = false
            throw InMemoryRepositoryError.simulatedFailure
        }
        for snapshot in changeSet.snapshots { snapshots[snapshot.entityID] = snapshot }
        for event in changeSet.events where events[event.id.rawValue] == nil {
            events[event.id.rawValue] = event
        }
    }

    public func entity<Entity: SyncEntity>(_ type: Entity.Type, id: UUID) throws -> Entity? {
        try snapshots[id]?.decode(type)
    }

    public func entities<Entity: SyncEntity>(
        _ type: Entity.Type,
        in missionID: MissionID,
        includeDeleted: Bool
    ) throws -> [Entity] {
        try snapshots.values
            .filter { $0.missionID == missionID.rawValue && $0.entityType == Entity.syncEntityType }
            .filter { includeDeleted || !$0.isDeleted }
            .map { try $0.decode(type) }
    }

    public func missions(includeDeleted: Bool) throws -> [Mission] {
        let missions = try snapshots.values
            .filter { $0.entityType == .mission && (includeDeleted || !$0.isDeleted) }
            .map { try $0.decode(Mission.self) }
        return RepositoryOrdering.newestFirst(missions)
    }

    public func changeEvents(in missionID: MissionID) throws -> [ChangeEvent] {
        RepositoryOrdering.chronological(events.values.filter { $0.missionID == missionID })
    }

    public func latestTimestamp(of deviceID: DeviceID) throws -> HybridTimestamp? {
        events.values.map(\.timestamp).filter { $0.deviceID == deviceID }.max()
    }

    public func purgeMission(_ missionID: MissionID) throws {
        snapshots = snapshots.filter { $0.value.missionID != missionID.rawValue }
        events = events.filter { $0.value.missionID != missionID }
    }
}

public enum InMemoryRepositoryError: Error, Sendable {
    case simulatedFailure
}
