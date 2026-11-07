import Foundation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Ergebnis eines Abgleichs.
public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    public var imported = RemoteImportResult()
    /// Dateien (Fotos, Sprachnotizen, Zeichnungen), Schritt 55.
    public var filesUploaded = 0
    public var filesDownloaded = 0
    /// Dateien, die noch kein Gerät hochgeladen hat (oder beschädigt ankamen).
    public var filesMissing = 0

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
    private let files: AttachmentFileStore?
    private let now: () -> Date

    public init(
        repository: any EntityRepository & DocumentRepository,
        transport: any SyncTransport,
        clock: DeviceClock,
        deviceID: DeviceID,
        files: AttachmentFileStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.transport = transport
        self.deviceID = deviceID
        self.files = files
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

        // 3. Dateien: fehlende hochladen, fehlende holen (nur wenn der Transport das kann).
        if let files, let fileTransport = transport as? any SyncFileTransport {
            try await syncFiles(mission, files: files, transport: fileTransport, report: &report)
        }

        try update(mission) { $0.lastSyncAt = now() }
        return report
    }

    /// Dateien, auf die der Einsatz verweist, die hier noch fehlen oder beschädigt sind.
    public func missingFiles(for mission: MissionID) throws -> [FileAttachment] {
        guard let files else { return [] }
        return try attachments(of: mission).filter { !files.isIntact($0) }
    }

    private func attachments(of mission: MissionID) throws -> [FileAttachment] {
        MissionAttachments.all(
            journal: try repository.entities(JournalEntry.self, in: mission, includeDeleted: true),
            mapObjects: try repository.entities(MapObject.self, in: mission, includeDeleted: true)
        )
    }

    private func syncFiles(
        _ mission: MissionID,
        files: AttachmentFileStore,
        transport: any SyncFileTransport,
        report: inout SyncReport
    ) async throws {
        let all = try attachments(of: mission)
        var local: [String: FileAttachment] = [:]
        var absent: [FileAttachment] = []
        for file in all {
            if files.isIntact(file) {
                local[file.sha256] = local[file.sha256] ?? file
            } else {
                absent.append(file)
            }
        }

        let wanted = try await transport.missingFiles(local.keys.sorted(), mission: mission)
        for hash in wanted {
            guard let file = local[hash], let data = files.data(for: file) else { continue }
            try await transport.uploadFile(data, sha256: hash, mission: mission)
            report.filesUploaded += 1
        }

        for file in absent {
            guard let data = try await transport.downloadFile(sha256: file.sha256, mission: mission) else {
                report.filesMissing += 1
                continue
            }
            do {
                try files.store(data, for: file)
                report.filesDownloaded += 1
            } catch AttachmentStoreError.checksumMismatch {
                report.filesMissing += 1
            }
        }
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
