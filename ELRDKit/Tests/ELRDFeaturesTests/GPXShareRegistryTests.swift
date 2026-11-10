import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures

@Suite("GPX-Freigaben für Hundeteams (Schritt 120)")
struct GPXShareRegistryTests {
    private func publication(_ name: String) -> GPXPublication {
        GPXPublication(fileName: name, title: name, link: URL(string: "https://www.icloud.com/iclouddrive/0abc#\(name)")!,
                       publishedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: nil)
    }

    @Test func recordsReplacesAndRemoves() throws {
        let mission = MissionID()
        var registry = GPXShareRegistry()
        registry.record(publication("Lagekarte.gpx"), for: mission)
        registry.record(publication("Sperrzone.gpx"), for: mission)
        registry.record(publication("Lagekarte.gpx"), for: mission)
        #expect(registry.publications(for: mission).map(\.fileName) == ["Sperrzone.gpx", "Lagekarte.gpx"], "gleiche Datei ersetzt")
        registry.remove(fileName: "Sperrzone.gpx", for: mission)
        #expect(registry.publications(for: mission).count == 1)
        registry.removeAll(for: mission)
        #expect(registry.missions.isEmpty)
        let data = try JSONEncoder().encode(registry)
        #expect(try JSONDecoder().decode(GPXShareRegistry.self, from: data) == registry)
    }

    @Test func cleansOnlyClosedMissionsWhenEnabled() {
        let open = MissionID(), closed = MissionID()
        var registry = GPXShareRegistry()
        registry.record(publication("A.gpx"), for: open)
        registry.record(publication("B.gpx"), for: closed)
        #expect(registry.missionsToClean(closed: [closed], deletesOnClose: true) == [closed])
        #expect(registry.missionsToClean(closed: [closed], deletesOnClose: false).isEmpty, "Einstellung aus: nichts löschen")
        #expect(registry.missionsToClean(closed: [], deletesOnClose: true).isEmpty)
    }
}
