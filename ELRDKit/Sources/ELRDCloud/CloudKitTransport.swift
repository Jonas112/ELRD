import Foundation
import ELRDDomain
import ELRDSync

/// Abgleich über iCloud: setzt `SyncTransport` auf eine Zone je Einsatz um.
///
/// - Jedes Ereignis ist ein Datensatz mit der Ereignis-ID als Namen; Hochladen
///   ist dadurch idempotent (erneut speichern = identisch überschreiben).
/// - Ein Paket wird atomar gespeichert: ganz oder gar nicht. Der Hochlade-Stand
///   der Engine rückt nur nach vollständigem Erfolg vor.
/// - Abholen nutzt den Änderungsstand der Zone (`CKServerChangeToken`) als Cursor.
///   CloudKit liefert Datensätze, die erneut gespeichert wurden, noch einmal –
///   die Übernahme ignoriert Bekanntes.
///
/// Als `actor` sind die Zuordnungen Einsatz → Zone vor gleichzeitigen Zugriffen
/// geschützt. Zwischen zwei `await` kann sich die Zuordnung ändern (Teilen
/// beendet); ein Aufruf arbeitet dann mit der Zone, die beim Start galt, und der
/// nächste Lauf meldet „nicht verbunden“.
public actor CloudKitTransport: SyncTransport, SyncFileTransport {
    private let store: any CloudZoneStore
    private var zones: [MissionID: CloudZone] = [:]
    /// Eigene Zonen, die in dieser Sitzung sicher angelegt sind.
    private var ensured: Set<CloudZone> = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    /// Ereignisse, die beim Abholen nicht lesbar waren (beschädigt).
    public private(set) var unreadableEvents = 0

    public init(store: any CloudZoneStore) {
        self.store = store
    }

    // MARK: Zuordnung

    public func connect(_ mission: MissionID, to zone: CloudZone) {
        zones[mission] = zone
    }

    public func disconnect(_ mission: MissionID) {
        if let zone = zones.removeValue(forKey: mission) { ensured.remove(zone) }
    }

    public func disconnectAll() {
        zones.removeAll()
        ensured.removeAll()
    }

    public func zone(for mission: MissionID) -> CloudZone? { zones[mission] }

    /// Nach dem Löschen der Zone von außen (z. B. Neuaufbau nach Schlüsselverlust).
    public func forgetEnsured(_ zone: CloudZone) {
        ensured.remove(zone)
    }

    // MARK: SyncTransport

    public func push(_ events: [ChangeEvent], mission: MissionID) async throws {
        let zone = try connectedZone(mission)
        let records = try events.filter { $0.missionID == mission }.map { event in
            CloudRecord(name: event.id.rawValue.uuidString.lowercased(), kind: .event, payload: try encoder.encode(event))
        }
        guard !records.isEmpty else { return }
        try await mapErrors(zone) { try await self.save(records, in: zone) }
    }

    public func pull(mission: MissionID, after cursor: SyncCursor?, limit: Int) async throws -> SyncPage {
        let zone = try connectedZone(mission)
        let page = try await mapErrors(zone) {
            try await self.store.changes(in: zone, since: cursor?.token, limit: max(limit, 1))
        }
        var events: [ChangeEvent] = []
        for record in page.records where record.kind == .event {
            guard let event = try? decoder.decode(ChangeEvent.self, from: record.payload) else {
                unreadableEvents += 1
                continue
            }
            if event.missionID == mission { events.append(event) }
        }
        let position = (cursor?.position ?? 0) + Int64(page.records.count)
        let next = page.token.map { SyncCursor(position, token: $0) } ?? cursor
        return SyncPage(events: events, cursor: next, hasMore: page.moreComing)
    }

    public func purge(mission: MissionID) async throws {
        guard let zone = zones[mission] else { return }
        try await mapErrors(zone) { try await self.store.deleteZone(zone) }
        disconnect(mission)
    }

    // MARK: SyncFileTransport

    public func missingFiles(_ sha256: [String], mission: MissionID) async throws -> [String] {
        let zone = try connectedZone(mission)
        guard !sha256.isEmpty else { return [] }
        if zone.scope == .owned { try await mapErrors(zone) { try await self.ensureZone(zone) } }
        let names = sha256.map(CloudRecord.fileName(sha256:))
        let present = try await mapErrors(zone) { try await self.store.existing(names, in: zone) }
        return sha256.filter { !present.contains(CloudRecord.fileName(sha256: $0)) }
    }

    public func uploadFile(_ data: Data, sha256: String, mission: MissionID) async throws {
        let zone = try connectedZone(mission)
        let record = CloudRecord(name: CloudRecord.fileName(sha256: sha256), kind: .file, payload: data)
        // Zwei Geräte mit derselben Datei: gleicher Name, gleicher Inhalt – wer zuletzt
        // speichert, überschreibt identisch.
        try await mapErrors(zone) { try await self.save([record], in: zone) }
    }

    public func downloadFile(sha256: String, mission: MissionID) async throws -> Data? {
        let zone = try connectedZone(mission)
        return try await mapErrors(zone) {
            try await self.store.fetch(CloudRecord.fileName(sha256: sha256), in: zone)?.payload
        }
    }

    // MARK: Intern

    private func connectedZone(_ mission: MissionID) throws -> CloudZone {
        guard let zone = zones[mission] else { throw SyncError.notConnected }
        return zone
    }

    private func ensureZone(_ zone: CloudZone) async throws {
        guard zone.scope == .owned, !ensured.contains(zone) else { return }
        // Anlegen ist idempotent; überschneiden sich zwei Aufrufe, legen beide an.
        try await store.createZone(zone)
        ensured.insert(zone)
    }

    /// Speichert atomar; legt die eigene Zone bei Bedarf an und teilt zu große Pakete.
    private func save(_ records: [CloudRecord], in zone: CloudZone) async throws {
        try await ensureZone(zone)
        do {
            try await store.save(records, in: zone)
        } catch CloudStoreError.zoneMissing where zone.scope == .owned {
            // Zone wurde gelöscht (anderes Gerät desselben Kontos, Zurücksetzen):
            // neu anlegen und das Paket noch einmal speichern.
            ensured.remove(zone)
            try await ensureZone(zone)
            try await store.save(records, in: zone)
        } catch CloudStoreError.batchTooLarge where records.count > 1 {
            let middle = records.count / 2
            try await save(Array(records[..<middle]), in: zone)
            try await save(Array(records[middle...]), in: zone)
        }
    }

    private func mapErrors<Value: Sendable>(
        _ zone: CloudZone,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as CloudStoreError {
            throw error.syncError(scope: zone.scope)
        }
    }
}
