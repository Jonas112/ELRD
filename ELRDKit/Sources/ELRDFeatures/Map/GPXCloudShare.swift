import Foundation
import Observation
import ELRDDomain

// MARK: - GPX für Hundeteams per Link/QR-Code (Schritt 120, E120)
//
// Die Datei liegt im iCloud Drive der App (Container `iCloud.ELRD.App`, Ordner
// `Freigaben/<Einsatz>/`). iCloud liefert dazu einen öffentlichen Download-Link
// (`url(forPublishingUbiquitousItemAt:)`) – Empfänger brauchen weder ELRD noch ein
// Apple-Konto. Bei Einsatzende (Einstellung, Standard an) wird der Ordner gelöscht.

/// Eine veröffentlichte GPX-Datei.
struct GPXPublication: Codable, Hashable, Identifiable, Sendable {
    let fileName: String
    let title: String
    let link: URL
    let publishedAt: Date
    let expiresAt: Date?

    var id: String { fileName }
}

/// Welche Freigaben es je Einsatz gibt (Gerätedatei, nur auf diesem Gerät).
struct GPXShareRegistry: Codable, Equatable, Sendable {
    private(set) var entries: [String: [GPXPublication]] = [:]

    func publications(for mission: MissionID) -> [GPXPublication] {
        entries[mission.rawValue.uuidString] ?? []
    }

    mutating func record(_ publication: GPXPublication, for mission: MissionID) {
        var list = publications(for: mission).filter { $0.fileName != publication.fileName }
        list.append(publication)
        entries[mission.rawValue.uuidString] = list
    }

    mutating func remove(fileName: String, for mission: MissionID) {
        let list = publications(for: mission).filter { $0.fileName != fileName }
        entries[mission.rawValue.uuidString] = list.isEmpty ? nil : list
    }

    mutating func removeAll(for mission: MissionID) {
        entries[mission.rawValue.uuidString] = nil
    }

    var missions: [MissionID] { entries.keys.compactMap(MissionID.init(uuidString:)) }

    /// Einsätze, deren Freigaben gelöscht werden sollen: beendet und Einstellung an.
    func missionsToClean(closed: Set<MissionID>, deletesOnClose: Bool) -> [MissionID] {
        guard deletesOnClose else { return [] }
        return missions.filter { closed.contains($0) }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }
}

enum GPXShareError: LocalizedError {
    case iCloudUnavailable
    case notUploaded

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable: "iCloud Drive ist auf diesem Gerät nicht verfügbar (iCloud-Anmeldung und „iCloud Drive“ prüfen)."
        case .notUploaded: "Die Datei ist noch nicht in iCloud angekommen. Bitte Netz prüfen und erneut versuchen."
        }
    }
}

/// Verwaltet die Freigaben dieses Geräts.
@MainActor
@Observable
final class GPXShareCenter {
    static let shared = GPXShareCenter()

    private(set) var registry: GPXShareRegistry
    @ObservationIgnored private let registryURL: URL

    private init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        registryURL = support.appendingPathComponent("gpx-freigaben.json")
        registry = (try? JSONDecoder().decode(GPXShareRegistry.self, from: Data(contentsOf: registryURL))) ?? GPXShareRegistry()
    }

    func publications(for mission: MissionID) -> [GPXPublication] {
        registry.publications(for: mission)
    }

    /// Datei ablegen, auf das Hochladen warten und den öffentlichen Link holen.
    func publish(_ contents: String, title: String, mission: MissionID) async throws -> GPXPublication {
        let fileName = GPXExport.fileName(title)
        let data = Data(contents.utf8)
        let folderName = mission.rawValue.uuidString
        let result = try await Task.detached(priority: .userInitiated) { () throws -> (URL, Date?) in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                throw GPXShareError.iCloudUnavailable
            }
            let folder = container.appendingPathComponent("Freigaben", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(fileName)
            try GPXShareCenter.coordinatedWrite(data, to: file)
            // iCloud gibt den Link erst, wenn die Datei hochgeladen ist (bis ca. 60 s warten).
            var lastError: (any Error)?
            for _ in 0..<30 {
                do {
                    var expiration: NSDate?
                    let link = try FileManager.default.url(forPublishingUbiquitousItemAt: file, expiration: &expiration)
                    return (link, expiration as Date?)
                } catch {
                    lastError = error
                    try await Task.sleep(for: .seconds(2))
                }
            }
            throw lastError ?? GPXShareError.notUploaded
        }.value
        let publication = GPXPublication(fileName: fileName, title: title, link: result.0, publishedAt: Date(), expiresAt: result.1)
        registry.record(publication, for: mission)
        persist()
        return publication
    }

    /// Letzter Fehler beim Löschen (für die Einstellungen; ohne Datei- oder Einsatznamen).
    private(set) var lastDeleteError: String?

    /// Eine Freigabe beenden (Datei in iCloud löschen).
    func remove(_ publication: GPXPublication, mission: MissionID) async {
        let folderName = mission.rawValue.uuidString
        let fileName = publication.fileName
        let deleted = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let folder = GPXShareCenter.folder(named: folderName) else { return false }
            return GPXShareCenter.coordinatedDelete(folder.appendingPathComponent(fileName))
        }.value
        guard deleted else {
            lastDeleteError = "Die Freigabe konnte nicht gelöscht werden (iCloud nicht erreichbar). Neuer Versuch folgt automatisch."
            return
        }
        lastDeleteError = nil
        registry.remove(fileName: fileName, for: mission)
        persist()
    }

    /// Alle Freigaben eines Einsatzes löschen (Einsatzende).
    ///
    /// Schritt 125: Jede Datei wird einzeln gelöscht – nur `removeItem` auf der Datei
    /// selbst macht laut Apple die veröffentlichten Links ungültig. Erst wenn alles
    /// gelöscht ist, verschwindet der Einsatz aus der Liste; sonst wird es beim
    /// nächsten Aufräumen (Einsatzliste, alle 30 s) erneut versucht.
    @discardableResult
    func removeAll(for mission: MissionID) async -> Bool {
        let fileNames = registry.publications(for: mission).map(\.fileName)
        guard !fileNames.isEmpty else { return true }
        let folderName = mission.rawValue.uuidString
        let deleted = await Task.detached(priority: .utility) { () -> Bool in
            guard let folder = GPXShareCenter.folder(named: folderName) else { return false }
            let present = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let files = Set(present + fileNames.map { folder.appendingPathComponent($0) })
            var allDeleted = true
            for file in files where !GPXShareCenter.coordinatedDelete(file) { allDeleted = false }
            if allDeleted { _ = GPXShareCenter.coordinatedDelete(folder) }
            return allDeleted
        }.value
        guard deleted else {
            lastDeleteError = "GPX-Freigaben konnten nicht gelöscht werden (iCloud nicht erreichbar). Neuer Versuch folgt automatisch."
            return false
        }
        lastDeleteError = nil
        registry.removeAll(for: mission)
        persist()
        return true
    }

    /// Anzahl aller Freigaben auf diesem Gerät.
    var publicationCount: Int {
        registry.missions.reduce(0) { $0 + registry.publications(for: $1).count }
    }

    /// Alle Freigaben aller Einsätze löschen (Einstellungen).
    func removeEverything() async {
        for mission in registry.missions { await removeAll(for: mission) }
    }

    /// Beendete Einsätze aufräumen (beim Start, in der Einsatzliste, bei Einsatzende).
    func cleanUp(closed: Set<MissionID>, deletesOnClose: Bool) async {
        for mission in registry.missionsToClean(closed: closed, deletesOnClose: deletesOnClose) {
            await removeAll(for: mission)
        }
    }

    private func persist() {
        try? JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
    }

    // MARK: Dateizugriff (koordiniert, wie Apple es für iCloud Drive verlangt)

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? (writeError as NSError?) { throw error }
    }

    nonisolated private static func folder(named name: String) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Freigaben", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Löscht koordiniert; `true`, wenn die Datei danach nicht mehr existiert.
    nonisolated private static func coordinatedDelete(_ url: URL) -> Bool {
        var coordinationError: NSError?
        var deleteError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Schon weg – gilt als gelöscht.
            } catch {
                deleteError = error
            }
        }
        if coordinationError == nil, deleteError == nil { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
