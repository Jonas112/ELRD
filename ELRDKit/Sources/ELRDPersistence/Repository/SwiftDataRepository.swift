import Foundation
import SwiftData
import ELRDDomain
import ELRDSync

/// `EntityRepository` auf Basis von SwiftData (Speicherung auf dem Gerät).
@MainActor
public final class SwiftDataRepository: EntityRepository {
    private let context: ModelContext
    /// Für Erweiterungen in diesem Modul (Dokumente).
    var modelContext: ModelContext { context }

    public init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func apply(_ changeSet: ChangeSet) throws {
        guard !changeSet.isEmpty else { return }
        do {
            for snapshot in changeSet.snapshots {
                if let record = try record(for: snapshot.entityID) {
                    try snapshot.checkCanReplace(storedVersion: record.entityVersion, storedPayload: record.payload)
                    try RecordMapping.update(record, with: snapshot)
                } else {
                    context.insert(RecordMapping.makeRecord(snapshot))
                }
            }
            for event in changeSet.events {
                // Doppelt empfangene Ereignisse (Sync) nur einmal speichern.
                if try eventExists(event.id.rawValue) { continue }
                context.insert(try RecordMapping.makeRecord(event))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func entity<Entity: SyncEntity>(_ type: Entity.Type, id: UUID) throws -> Entity? {
        guard let record = try record(for: id) else { return nil }
        return try RecordMapping.decode(type, from: record)
    }

    public func entities<Entity: SyncEntity>(
        _ type: Entity.Type,
        in missionID: MissionID,
        includeDeleted: Bool
    ) throws -> [Entity] {
        let mission = missionID.rawValue
        let typeName = Entity.syncEntityType.rawValue
        let descriptor = FetchDescriptor<EntityRecord>(
            predicate: #Predicate { $0.missionID == mission && $0.entityType == typeName }
        )
        return try context.fetch(descriptor)
            .filter { includeDeleted || !$0.isSoftDeleted }
            .map { try RecordMapping.decode(type, from: $0) }
    }

    public func missions(includeDeleted: Bool) throws -> [Mission] {
        let typeName = SyncEntityType.mission.rawValue
        let descriptor = FetchDescriptor<EntityRecord>(predicate: #Predicate { $0.entityType == typeName })
        let missions = try context.fetch(descriptor)
            .filter { includeDeleted || !$0.isSoftDeleted }
            .map { try RecordMapping.decode(Mission.self, from: $0) }
        return RepositoryOrdering.newestFirst(missions)
    }

    public func changeEvents(in missionID: MissionID) throws -> [ChangeEvent] {
        let mission = missionID.rawValue
        let descriptor = FetchDescriptor<ChangeRecord>(predicate: #Predicate { $0.missionID == mission })
        // Endgültige Reihenfolge über `HybridTimestamp` (inkl. Geräte-ID als Gleichstandsregel).
        return RepositoryOrdering.chronological(try context.fetch(descriptor).map(RecordMapping.decode))
    }

    public func latestTimestamp(of deviceID: DeviceID) throws -> HybridTimestamp? {
        let device = deviceID.rawValue
        var descriptor = FetchDescriptor<ChangeRecord>(
            predicate: #Predicate { $0.deviceID == device },
            sortBy: [SortDescriptor(\.wallTime, order: .reverse), SortDescriptor(\.counter, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return HybridTimestamp(wallTime: record.wallTime, counter: record.counter, deviceID: deviceID)
    }

    public func purgeMission(_ missionID: MissionID) throws {
        let mission = missionID.rawValue
        do {
            try context.delete(model: EntityRecord.self, where: #Predicate { $0.missionID == mission })
            try context.delete(model: ChangeRecord.self, where: #Predicate { $0.missionID == mission })
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: Hilfen

    private func record(for entityID: UUID) throws -> EntityRecord? {
        var descriptor = FetchDescriptor<EntityRecord>(predicate: #Predicate { $0.entityID == entityID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func eventExists(_ eventID: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<ChangeRecord>(predicate: #Predicate { $0.eventID == eventID })
        descriptor.fetchLimit = 1
        return try context.fetchCount(descriptor) > 0
    }
}
