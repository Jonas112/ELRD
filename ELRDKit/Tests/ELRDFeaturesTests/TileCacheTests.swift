import Foundation
import Testing
@testable import ELRDFeatures

@Suite("Offline-Karte: Kachelspeicher (Schritt 59)")
struct TileCacheTests {
    private func makeCache(maximumBytes: Int = 1_000_000) -> TileDiskCache {
        TileDiskCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString)", isDirectory: true),
            maximumBytes: maximumBytes
        )
    }

    @Test func storesAndReadsTilesPerLayer() {
        let cache = makeCache()
        defer { cache.clear() }
        #expect(cache.entry(layer: .openStreetMap, z: 15, x: 17300, y: 11000) == nil)
        cache.store(Data("kachel".utf8), layer: .openStreetMap, z: 15, x: 17300, y: 11000)
        let entry = cache.entry(layer: .openStreetMap, z: 15, x: 17300, y: 11000)
        #expect(entry?.data == Data("kachel".utf8))
        #expect(entry?.isStale == false)
        #expect(cache.entry(layer: .openTopoMap, z: 15, x: 17300, y: 11000) == nil, "jede Karte eigener Speicher")
        let later = Date().addingTimeInterval(cache.refreshAge + 60)
        #expect(cache.entry(layer: .openStreetMap, z: 15, x: 17300, y: 11000, now: later)?.isStale == true, "alt → neu laden, wenn Netz da")
        #expect(cache.sizeInBytes() == 6)
        cache.clear()
        #expect(cache.sizeInBytes() == 0)
    }

    @Test func pruneRemovesOldestUntilUnderLimit() throws {
        let cache = makeCache(maximumBytes: 25)
        defer { cache.clear() }
        for x in 0..<5 {
            cache.store(Data(repeating: UInt8(x), count: 10), layer: .openStreetMap, z: 10, x: x, y: 0)
            let file = cache.url(layer: .openStreetMap, z: 10, x: x, y: 0)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(x))], ofItemAtPath: file.path)
        }
        #expect(cache.sizeInBytes() == 50)
        #expect(cache.prune() == 3)
        #expect(cache.sizeInBytes() == 20)
        #expect(cache.entry(layer: .openStreetMap, z: 10, x: 0, y: 0) == nil, "älteste zuerst")
        #expect(cache.entry(layer: .openStreetMap, z: 10, x: 4, y: 0) != nil)
    }
}

import CoreLocation

@Suite("Einsatzort aus eigenem Standort (Schritt 61)")
struct MyLocationTests {
    @Test func onlyFreshAndPreciseFixesAreUsed() {
        let now = Date()
        func fix(accuracy: Double, age: TimeInterval) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 50.05, longitude: 10.23), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 10, timestamp: now.addingTimeInterval(-age))
        }
        #expect(LocationAccess.isUsable(fix(accuracy: 15, age: 10), now: now))
        #expect(!LocationAccess.isUsable(fix(accuracy: 500, age: 10), now: now), "zu ungenau")
        #expect(!LocationAccess.isUsable(fix(accuracy: 15, age: 600), now: now), "zu alt")
        #expect(!LocationAccess.isUsable(fix(accuracy: -1, age: 0), now: now), "ungültig")
    }
}
