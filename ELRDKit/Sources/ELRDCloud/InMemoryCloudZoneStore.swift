import Foundation

/// iCloud-Ersatz im Arbeitsspeicher für Beispieldaten und Vorschauen (ein Konto,
/// keine Fehler). Echte Tests verwenden eine ausführlichere Nachbildung.
public actor InMemoryCloudZoneStore: CloudZoneStore {
    private var zones: [String: [String: (record: CloudRecord, sequence: Int64)]] = [:]
    private var sequence: Int64 = 0
    private var shares: [String: URL] = [:]

    public init() {}

    public func accountID() async throws -> String { "demo" }

    public func createZone(_ zone: CloudZone) async throws {
        if zones[zone.zoneName] == nil { zones[zone.zoneName] = [:] }
    }

    public func deleteZone(_ zone: CloudZone) async throws {
        zones[zone.zoneName] = nil
        shares[zone.zoneName] = nil
    }

    public func save(_ records: [CloudRecord], in zone: CloudZone) async throws {
        guard zones[zone.zoneName] != nil else { throw CloudStoreError.zoneMissing }
        for record in records {
            sequence += 1
            zones[zone.zoneName]?[record.name] = (record, sequence)
        }
    }

    public func changes(in zone: CloudZone, since token: Data?, limit: Int) async throws -> CloudChangePage {
        guard let stored = zones[zone.zoneName] else { throw CloudStoreError.zoneMissing }
        let after = token.flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
        let changed = stored.values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
        let page = Array(changed.prefix(limit))
        let last = page.last?.sequence ?? max(after, sequence)
        return CloudChangePage(
            records: page.map(\.record),
            token: Data(String(last).utf8),
            moreComing: changed.count > page.count
        )
    }

    public func existing(_ names: [String], in zone: CloudZone) async throws -> Set<String> {
        Set(names.filter { zones[zone.zoneName]?[$0] != nil })
    }

    public func fetch(_ name: String, in zone: CloudZone) async throws -> CloudRecord? {
        zones[zone.zoneName]?[name]?.record
    }

    public func share(_ zone: CloudZone, title: String) async throws -> URL {
        try await createZone(zone)
        if let url = shares[zone.zoneName] { return url }
        let url = URL(string: "https://www.icloud.com/share/0Beispiel\(shares.count + 1)ELRD")!
        shares[zone.zoneName] = url
        return url
    }

    public func stopSharing(_ zone: CloudZone) async throws {
        shares[zone.zoneName] = nil
    }

    public func accept(_ url: URL) async throws -> CloudZone {
        guard let name = shares.first(where: { $0.value == url })?.key else { throw CloudStoreError.invalidShare }
        return CloudZone(scope: .owned, zoneName: name, ownerName: CloudZone.currentUser)
    }

    public func subscribeToChanges() async throws {}
}
