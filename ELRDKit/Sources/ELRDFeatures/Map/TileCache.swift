import Foundation
import MapKit
import Network
import Observation

// MARK: - Offline-Karte (Schritt 59)

/// Speicher für Kartenkacheln (OpenStreetMap, OpenTopoMap) im Cache-Ordner der App.
///
/// - Zuerst aus dem Speicher: schneller am Einsatzort und schont die Kachel-Server
///   (OSM verlangt mindestens 7 Tage Zwischenspeichern).
/// - Ältere Kacheln als `refreshAge` werden neu geladen, wenn Netz da ist; ohne Netz
///   bleibt die alte Kachel stehen.
/// - Über `maximumBytes` werden die am längsten nicht genutzten Kacheln entfernt.
/// Apple-Karten speichert MapKit selbst.
final class TileDiskCache: @unchecked Sendable {
    static let shared = TileDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapTiles", isDirectory: true)
    )

    let directory: URL
    let maximumBytes: Int
    let refreshAge: TimeInterval

    init(directory: URL, maximumBytes: Int = 300 * 1024 * 1024, refreshAge: TimeInterval = 7 * 24 * 60 * 60) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.refreshAge = refreshAge
    }

    func url(layer: MapBaseLayer, z: Int, x: Int, y: Int) -> URL {
        directory
            .appendingPathComponent(layer.rawValue, isDirectory: true)
            .appendingPathComponent("\(z)", isDirectory: true)
            .appendingPathComponent("\(x)", isDirectory: true)
            .appendingPathComponent("\(y).png")
    }

    struct Entry {
        let data: Data
        let isStale: Bool
    }

    func entry(layer: MapBaseLayer, z: Int, x: Int, y: Int, now: Date = Date()) -> Entry? {
        let file = url(layer: layer, z: z, x: x, y: y)
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Entry(data: data, isStale: now.timeIntervalSince(modified) > refreshAge)
    }

    func store(_ data: Data, layer: MapBaseLayer, z: Int, x: Int, y: Int) {
        guard !data.isEmpty else { return }
        let file = url(layer: layer, z: z, x: x, y: y)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // Speicher voll o. Ä.: Kachel einfach nicht merken.
        }
    }

    /// Belegter Platz in Byte.
    func sizeInBytes() -> Int {
        files().reduce(0) { $0 + $1.size }
    }

    /// Entfernt die ältesten Kacheln, bis höchstens `maximumBytes` belegt sind.
    @discardableResult
    func prune() -> Int {
        var all = files()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > maximumBytes else { return 0 }
        all.sort { $0.modified < $1.modified }
        var removed = 0
        for file in all where total > maximumBytes {
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
                removed += 1
            }
        }
        return removed
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct FileInfo {
        let url: URL
        let size: Int
        let modified: Date
    }

    private func files() -> [FileInfo] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var result: [FileInfo] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            result.append(FileInfo(url: file, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast))
        }
        return result
    }
}

/// Kachel-Overlay mit Speicher: erst lokal, sonst Netz; ohne Netz alte Kachel.
final class CachingTileOverlay: MKTileOverlay {
    let layer: MapBaseLayer
    let cache: TileDiskCache

    init(layer: MapBaseLayer, cache: TileDiskCache = .shared) {
        self.layer = layer
        self.cache = cache
        super.init(urlTemplate: layer.tileTemplate)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let layer = layer
        let cache = cache
        let cached = cache.entry(layer: layer, z: path.z, x: path.x, y: path.y)
        if let cached, !cached.isStale {
            result(cached.data, nil)
            return
        }
        super.loadTile(at: path) { data, error in
            if let data, !data.isEmpty {
                cache.store(data, layer: layer, z: path.z, x: path.x, y: path.y)
                result(data, nil)
            } else if let cached {
                result(cached.data, nil)
            } else {
                result(nil, error)
            }
        }
    }
}

/// Netzstatus für den Hinweis „Karte offline“.
@MainActor
@Observable
final class NetworkStatus {
    static let shared = NetworkStatus()

    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "ELRD.NetworkStatus"))
    }
}
