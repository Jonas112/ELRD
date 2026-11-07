import Foundation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Ergebnis eines Abgleichs.
public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    public var imported = RemoteImportResult()

    public init() {}
}

/// Gleicht einen Einsatz mit dem Server ab (Schritt 53): erst eigene Änderungen
/// hochladen, dann fremde abholen und zusammenführen. Der Stand wird nach jedem
/// Teilschritt gesichert – bricht die Verbindung ab, geht es beim nächsten Mal
/// an derselben Stelle weiter, ohne etwas doppelt zu übernehmen.
///
/// Lokal bleibt alles voll nutzbar; der Abgleich ist nie Voraussetzung.
@MainActor
public final class SyncEngine {
    public static let pushBatchSize = 200
    public static let pullPageSize = 500

    private let repository: any EntityRepository & DocumentRepository
    private let transport: any SyncTransport
    private let deviceID: DeviceID
    private let importer: RemoteChangeImporter
    private let now: () -> Date

    public init(
        repository: any EntityRepository & DocumentRepository,
        transport: any SyncTransport,
        clock: DeviceClock,
        deviceID: DeviceID,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.transport = transport
        self.deviceID = deviceID
        self.now = now
        importer = RemoteChangeImporter(repository: repository, clock: clock, now: now)
    }

    /// Stand des Abgleichs für einen Einsatz.
    public func checkpoint(for mission: MissionID) throws -> SyncCheckpoint {
        try checkpoints()[mission]
    }

    /// Eigene Änderungen, die noch nicht beim Server sind.
    public func pendingCount(for mission: MissionID) throws -> Int {
        try checkpoint(for: mission).outbox(repository.changeEvents(in: mission), device: deviceID).count
    }

    @discardableResult
    public func sync(_ mission: MissionID) async throws -> SyncReport {
        var report = SyncReport()

        // 1. Hochladen, in Paketen; nach jedem Paket den Stand sichern.
        let outbox = try checkpoint(for: mission).outbox(repository.changeEvents(in: mission), device: deviceID)
        var start = 0
        while start < outbox.count {
            let batch = Array(outbox[start..<min(start + Self.pushBatchSize, outbox.count)])
            try await transport.push(batch, mission: mission)
            try update(mission) { $0.pushedThrough = batch.last?.timestamp }
            report.pushed += batch.count
            start += batch.count
        }

        // 2. Abholen und zusammenführen, Seite für Seite.
        var hasMore = true
        while hasMore {
            let cursor = try checkpoint(for: mission).pullCursor
            let page = try await transport.pull(mission: mission, after: cursor, limit: Self.pullPageSize)
            let result = try importer.importEvents(page.events)
            report.pulled += page.events.count
            report.imported.newEvents += result.newEvents
            report.imported.changedEntities += result.changedEntities
            report.imported.clockWarnings += result.clockWarnings
            report.imported.missions.formUnion(result.missions)
            try update(mission) { $0.pullCursor = page.cursor ?? $0.pullCursor }
            hasMore = page.hasMore && !page.events.isEmpty
        }

        try update(mission) { $0.lastSyncAt = now() }
        return report
    }

    /// Vergisst den Abgleich eines Einsatzes (z. B. nach endgültigem Löschen).
    public func forget(_ mission: MissionID) throws {
        var all = try checkpoints()
        all.remove(mission)
        try repository.saveDocument(all, key: .syncCheckpoints, at: now())
    }

    private func checkpoints() throws -> SyncCheckpoints {
        try repository.document(SyncCheckpoints.self, key: .syncCheckpoints) ?? SyncCheckpoints()
    }

    private func update(_ mission: MissionID, _ change: (inout SyncCheckpoint) -> Void) throws {
        var all = try checkpoints()
        var checkpoint = all[mission]
        change(&checkpoint)
        all[mission] = checkpoint
        try repository.saveDocument(all, key: .syncCheckpoints, at: now())
    }
}
