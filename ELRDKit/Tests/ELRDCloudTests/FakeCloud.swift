import Foundation
@testable import ELRDCloud

/// Nachbildung von iCloud für Tests: mehrere Konten, eigene und geteilte Zonen,
/// atomares Speichern, Änderungsstände, Freigaben und gezielte Fehler.
actor FakeCloudServer {
    enum Operation: Sendable { case save, changes, share, accept, any }

    private struct Zone {
        var epoch: Int
        var records: [String: (record: CloudRecord, sequence: Int64)] = [:]
        var sequence: Int64 = 0
        var shareURL: URL?
        var participants: Set<String> = []
        var keysReset = false
    }

    private struct Token: Codable {
        let epoch: Int
        let sequence: Int64
        let generation: Int
    }

    private var zones: [String: Zone] = [:]
    private var epochs = 0
    private var failures: [(Operation, CloudStoreError)] = []
    private var tokenGeneration = 0
    private var delay: Duration = .zero

    var maxBatch = 400
    private(set) var saveCalls = 0
    private(set) var sharesCreated = 0

    // MARK: Steuerung für Tests

    func fail(_ operation: Operation, with error: CloudStoreError) { failures.append((operation, error)) }
    func setMaxBatch(_ value: Int) { maxBatch = value }
    func setDelay(_ value: Duration) { delay = value }
    /// Alle bisher ausgegebenen Stände laufen ab.
    func expireTokens() { tokenGeneration += 1 }
    func resetKeys(owner: String, zoneName: String) { zones[key(owner, zoneName)]?.keysReset = true }
    func eventCount(owner: String, zoneName: String) -> Int {
        zones[key(owner, zoneName)]?.records.values.filter { $0.record.kind == .event }.count ?? 0
    }
    func stopSharing(owner: String, zoneName: String) {
        zones[key(owner, zoneName)]?.shareURL = nil
        zones[key(owner, zoneName)]?.participants = []
    }
    func zoneExists(owner: String, zoneName: String) -> Bool { zones[key(owner, zoneName)] != nil }

    // MARK: Dienst

    private func key(_ owner: String, _ name: String) -> String { owner + "/" + name }

    private func pause() async {
        if delay > .zero { try? await Task.sleep(for: delay) }
    }

    private func checkFailure(_ operation: Operation) throws {
        if let index = failures.firstIndex(where: { $0.0 == operation || $0.0 == .any }) {
            throw failures.remove(at: index).1
        }
    }

    /// Schlüssel der Zone aus Sicht eines Kontos; prüft den Zugriff.
    private func resolve(_ zone: CloudZone, account: String) throws -> String {
        switch zone.scope {
        case .owned:
            return key(account, zone.zoneName)
        case .joined:
            let zoneKey = key(zone.ownerName, zone.zoneName)
            guard let stored = zones[zoneKey], stored.shareURL != nil, stored.participants.contains(account) else {
                throw CloudStoreError.zoneMissing
            }
            return zoneKey
        }
    }

    private func existingZone(_ zone: CloudZone, account: String) throws -> String {
        let zoneKey = try resolve(zone, account: account)
        guard let stored = zones[zoneKey] else { throw CloudStoreError.zoneMissing }
        if stored.keysReset { throw CloudStoreError.keyReset }
        return zoneKey
    }

    func createZone(_ zone: CloudZone, account: String) {
        let zoneKey = key(account, zone.zoneName)
        guard zones[zoneKey] == nil else { return }
        epochs += 1
        zones[zoneKey] = Zone(epoch: epochs)
    }

    func deleteZone(_ zone: CloudZone, account: String) {
        switch zone.scope {
        case .owned:
            zones[key(account, zone.zoneName)] = nil
        case .joined:
            zones[key(zone.ownerName, zone.zoneName)]?.participants.remove(account)
        }
    }

    func save(_ records: [CloudRecord], in zone: CloudZone, account: String) async throws {
        saveCalls += 1
        await pause()
        try checkFailure(.save)
        let zoneKey = try existingZone(zone, account: account)
        guard records.count <= maxBatch else { throw CloudStoreError.batchTooLarge }
        // Atomar: erst nach allen Prüfungen schreiben.
        var stored = zones[zoneKey]!
        for record in records {
            stored.sequence += 1
            stored.records[record.name] = (record, stored.sequence)
        }
        zones[zoneKey] = stored
    }

    func changes(in zone: CloudZone, since token: Data?, limit: Int, account: String) async throws -> CloudChangePage {
        await pause()
        try checkFailure(.changes)
        let zoneKey = try existingZone(zone, account: account)
        let stored = zones[zoneKey]!
        var after: Int64 = 0
        if let token {
            let decoded = try JSONDecoder().decode(Token.self, from: token)
            guard decoded.epoch == stored.epoch, decoded.generation == tokenGeneration else {
                throw CloudStoreError.tokenExpired
            }
            after = decoded.sequence
        }
        let changed = stored.records.values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
        let page = Array(changed.prefix(limit))
        let last = page.last?.sequence ?? max(after, stored.sequence)
        let records = page.map { entry in
            // Wie CloudKit mit `desiredKeys: [payload]`: Dateiinhalt bleibt leer.
            entry.record.kind == .file ? CloudRecord(name: entry.record.name, kind: .file, payload: Data()) : entry.record
        }
        return CloudChangePage(
            records: records,
            token: try JSONEncoder().encode(Token(epoch: stored.epoch, sequence: last, generation: tokenGeneration)),
            moreComing: changed.count > page.count
        )
    }

    func existing(_ names: [String], in zone: CloudZone, account: String) throws -> Set<String> {
        let zoneKey = try existingZone(zone, account: account)
        return Set(names.filter { zones[zoneKey]!.records[$0] != nil })
    }

    func fetch(_ name: String, in zone: CloudZone, account: String) throws -> CloudRecord? {
        let zoneKey = try existingZone(zone, account: account)
        return zones[zoneKey]!.records[name]?.record
    }

    func share(_ zone: CloudZone, account: String) async throws -> URL {
        try checkFailure(.share)
        createZone(zone, account: account)
        let zoneKey = key(account, zone.zoneName)
        if let url = zones[zoneKey]!.shareURL { return url }
        await pause()
        // Nach der Pause erneut prüfen – wie `.ifServerRecordUnchanged` bei CloudKit.
        if let url = zones[zoneKey]?.shareURL { return url }
        let url = URL(string: "https://www.icloud.com/share/\(UUID().uuidString)#\(account)/\(zone.zoneName)")!
        zones[zoneKey]?.shareURL = url
        sharesCreated += 1
        return url
    }

    func stopSharing(_ zone: CloudZone, account: String) {
        stopSharing(owner: account, zoneName: zone.zoneName)
    }

    func accept(_ url: URL, account: String) async throws -> CloudZone {
        await pause()
        try checkFailure(.accept)
        guard let fragment = url.fragment, let slash = fragment.firstIndex(of: "/") else { throw CloudStoreError.invalidShare }
        let owner = String(fragment[..<slash])
        let name = String(fragment[fragment.index(after: slash)...])
        let zoneKey = key(owner, name)
        guard zones[zoneKey]?.shareURL == url else { throw CloudStoreError.invalidShare }
        if owner == account { return CloudZone(scope: .owned, zoneName: name, ownerName: CloudZone.currentUser) }
        zones[zoneKey]?.participants.insert(account)
        return CloudZone(scope: .joined, zoneName: name, ownerName: owner)
    }
}

/// Zugang eines Geräts (eines Kontos) zur Nachbildung.
final class FakeCloudZoneStore: CloudZoneStore, @unchecked Sendable {
    let server: FakeCloudServer
    private let lock = NSLock()
    private var account: String?

    init(server: FakeCloudServer, account: String?) {
        self.server = server
        self.account = account
    }

    /// Anderes Konto anmelden (`nil` = abgemeldet).
    func switchAccount(to account: String?) {
        lock.withLock { self.account = account }
    }

    private func current() throws -> String {
        guard let account = lock.withLock({ account }) else { throw CloudStoreError.notSignedIn }
        return account
    }

    func accountID() async throws -> String { try current() }
    func createZone(_ zone: CloudZone) async throws {
        let account = try current()
        await server.createZone(zone, account: account)
    }
    func deleteZone(_ zone: CloudZone) async throws {
        let account = try current()
        await server.deleteZone(zone, account: account)
    }
    func save(_ records: [CloudRecord], in zone: CloudZone) async throws {
        let account = try current()
        try await server.save(records, in: zone, account: account)
    }
    func changes(in zone: CloudZone, since token: Data?, limit: Int) async throws -> CloudChangePage {
        let account = try current()
        return try await server.changes(in: zone, since: token, limit: limit, account: account)
    }
    func existing(_ names: [String], in zone: CloudZone) async throws -> Set<String> {
        let account = try current()
        return try await server.existing(names, in: zone, account: account)
    }
    func fetch(_ name: String, in zone: CloudZone) async throws -> CloudRecord? {
        let account = try current()
        return try await server.fetch(name, in: zone, account: account)
    }
    func share(_ zone: CloudZone, title: String) async throws -> URL {
        let account = try current()
        return try await server.share(zone, account: account)
    }
    func stopSharing(_ zone: CloudZone) async throws {
        let account = try current()
        await server.stopSharing(zone, account: account)
    }
    func accept(_ url: URL) async throws -> CloudZone {
        let account = try current()
        return try await server.accept(url, account: account)
    }
    func subscribeToChanges() async throws {}
}
