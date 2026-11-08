import Foundation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Ergebnis eines Abgleichs.
public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    /// Fremde Ereignisse, die dieses Gerät an den Server weitergeleitet hat.
    public var relayed = 0
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
///
/// **Gleichzeitigkeit:** Je Einsatz läuft höchstens ein Abgleich. Wer während
/// eines Laufs `sync` aufruft, bekommt einen *folgenden* Lauf (seine Änderungen
/// sind dann sicher dabei); alle, die währenddessen dazukommen, teilen sich diesen
/// einen wartenden Lauf. So entstehen keine verschränkten Stände, egal wie oft
/// Push, Zeitgeber und eigene Änderungen gleichzeitig auslösen. Stände werden nur
/// vorwärts gesetzt; Übernahmen sind idempotent – ein abgebrochener Lauf
/// wiederholt beim nächsten Mal höchstens etwas, verliert aber nichts.
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

    /// Ein geplanter Lauf; die Kennung unterscheidet Läufe desselben Einsatzes.
    private struct Run {
        let id: UUID
        let task: Task<SyncReport, any Error>
    }
    private var running: [MissionID: Run] = [:]
    private var waiting: [MissionID: Run] = [:]
    /// Für Tests: tatsächlich ausgeführte Läufe.
    private(set) var completedRuns = 0

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

    /// Gleicht den Einsatz ab. Läuft schon ein Abgleich, folgt ein weiterer
    /// (siehe Klassenbeschreibung); das Ergebnis ist das des Laufs, der die
    /// bis zum Aufruf gemachten Änderungen sicher enthält.
    @discardableResult
    public func sync(_ mission: MissionID) async throws -> SyncReport {
        try await schedule(mission).value
    }

    /// Ob für den Einsatz gerade ein Abgleich läuft oder wartet.
    public func isSyncing(_ mission: MissionID) -> Bool {
        running[mission] != nil || waiting[mission] != nil
    }

    /// Wartet, bis kein Abgleich des Einsatzes mehr läuft oder wartet
    /// (z. B. bevor der Stand nach einem Kontowechsel verworfen wird).
    public func waitUntilIdle(_ mission: MissionID) async {
        while let run = waiting[mission] ?? running[mission] {
            _ = try? await run.task.value
        }
    }

    private func schedule(_ mission: MissionID) -> Task<SyncReport, any Error> {
        // Ein wartender Lauf hat noch nicht begonnen: Er sieht alle bis jetzt
        // gemachten Änderungen – mitnutzen statt einen weiteren anzuhängen.
        if let queued = waiting[mission] { return queued.task }
        let previous = running[mission]?.task
        let id = UUID()
        let task = Task { @MainActor [self] () throws -> SyncReport in
            if let previous { _ = try? await previous.value }
            if waiting[mission]?.id == id {
                running[mission] = waiting[mission]
                waiting[mission] = nil
            }
            defer {
                if running[mission]?.id == id { running[mission] = nil }
                completedRuns += 1
            }
            return try await perform(mission)
        }
        let run = Run(id: id, task: task)
        if previous == nil {
            running[mission] = run
        } else {
            waiting[mission] = run
        }
        return task
    }

    private func perform(_ mission: MissionID) async throws -> SyncReport {
        var report = SyncReport()
        let events = try repository.changeEvents(in: mission)
        let start = try checkpoint(for: mission)

        // 1. Eigene Änderungen hochladen, in Paketen; nach jedem Paket den Stand sichern.
        let outbox = start.outbox(events, device: deviceID)
        for batch in outbox.chunked(Self.pushBatchSize) {
            try await transport.push(batch, mission: mission)
            try update(mission) { $0.advancePushed(to: batch.last?.timestamp) }
            report.pushed += batch.count
        }

        // 2. Fremde Ereignisse weiterleiten, die nicht über den Server kamen
        //    (Datei, iPad in der Nähe). Gezählt wird der Stand zu Laufbeginn:
        //    Was währenddessen dazukommt, erkennt der nächste Lauf.
        if let relay = start.relay(events, device: deviceID) {
            for batch in relay.chunked(Self.pushBatchSize) {
                try await transport.push(batch, mission: mission)
                report.relayed += batch.count
            }
            try update(mission) { $0.foreignAccounted = max($0.foreignAccounted ?? 0, relay.count) }
        }

        // 3. Abholen und zusammenführen, Seite für Seite. Erst übernehmen, dann den
        //    Stand sichern: Bricht es dazwischen ab, wird die Seite erneut geholt
        //    und doppelt Empfangenes ignoriert.
        var hasMore = true
        var restarted = false
        while hasMore {
            let cursor = try checkpoint(for: mission).pullCursor
            let page: SyncPage
            do {
                page = try await transport.pull(mission: mission, after: cursor, limit: Self.pullPageSize)
            } catch SyncError.cursorExpired where !restarted {
                restarted = true
                try update(mission) { $0.pullCursor = nil }
                continue
            }
            let result = try importer.importEvents(page.events)
            report.pulled += page.events.count
            report.imported.newEvents += result.newEvents
            report.imported.changedEntities += result.changedEntities
            report.imported.clockWarnings += result.clockWarnings
            report.imported.missions.formUnion(result.missions)
            try update(mission) {
                $0.pullCursor = page.cursor ?? $0.pullCursor
                // Neu vom Server übernommen = fremd und dort vorhanden.
                $0.foreignAccounted = ($0.foreignAccounted ?? 0) + result.newEvents
            }
            // Weiter, solange der Dienst mehr meldet und sich der Stand bewegt
            // (CloudKit kann Seiten ohne Ereignisse liefern, z. B. nur Dateien).
            hasMore = page.hasMore && (!page.events.isEmpty || page.cursor != cursor)
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
    /// Vorher `waitUntilIdle` abwarten, sonst schreibt ein laufender Abgleich
    /// seinen Stand danach wieder hinein.
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

extension Array {
    /// Teilt in aufeinanderfolgende Pakete höchstens dieser Größe.
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
