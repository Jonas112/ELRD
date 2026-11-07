import Foundation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Einsatz als Datei (Schritt 63): alle Änderungsereignisse plus Dateien.
///
/// Weil die Datei dieselben Ereignisse enthält wie der Abgleich, entsteht der
/// Einsatz auf dem anderen iPad über denselben Weg (`RemoteChangeImporter`):
/// Nummern, Autoren, Gelöschtes und das Protokoll bleiben erhalten, und ein
/// zweites Öffnen derselben Datei ändert nichts. Eine neuere Fassung desselben
/// Einsatzes ergänzt nur, was fehlt.
public struct MissionArchive: Codable, Sendable {
    /// Dateiendung (eigener Typ im Teilen-Menü wäre ein späterer Schritt).
    public static let fileExtension = "elrdeinsatz"
    public static let currentFormat = 1

    public struct File: Codable, Sendable, Equatable {
        public let attachment: FileAttachment
        public let data: Data
    }

    public let format: Int
    public let exportedAt: Date
    public let missionID: MissionID
    public let title: String
    public let events: [ChangeEvent]
    public let files: [File]

    /// Exportiert einen Einsatz. Dateien, die auf diesem Gerät fehlen, fehlen auch im Archiv.
    @MainActor
    public static func make(
        mission missionID: MissionID,
        repository: any EntityRepository,
        files store: AttachmentFileStore?,
        now: Date = Date()
    ) throws -> MissionArchive {
        guard let mission = try repository.entity(Mission.self, id: missionID.rawValue) else {
            throw CommandError.notFound(.mission)
        }
        let events = try repository.changeEvents(in: missionID).sorted { $0.timestamp < $1.timestamp }
        var archived: [File] = []
        if let store {
            let attachments = MissionAttachments.all(
                journal: try repository.entities(JournalEntry.self, in: missionID, includeDeleted: true),
                mapObjects: try repository.entities(MapObject.self, in: missionID, includeDeleted: true)
            )
            for attachment in attachments {
                guard store.isIntact(attachment), let data = store.data(for: attachment) else { continue }
                archived.append(File(attachment: attachment, data: data))
            }
        }
        return MissionArchive(
            format: currentFormat,
            exportedAt: now,
            missionID: missionID,
            title: "\(mission.displayNumber()) \(mission.title)",
            events: events,
            files: archived
        )
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MissionArchive {
        let decoder = JSONDecoder()
        let archive: MissionArchive
        do {
            archive = try decoder.decode(MissionArchive.self, from: data)
        } catch {
            throw MissionArchiveError.unreadable
        }
        guard archive.format <= currentFormat else { throw MissionArchiveError.newerFormat }
        guard archive.events.allSatisfy({ $0.missionID == archive.missionID }) else { throw MissionArchiveError.unreadable }
        return archive
    }

    /// Dateiname, z. B. „Einsatz 2026-6 VU mit mehreren Pkw.elrdeinsatz“.
    public var suggestedFileName: String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: ":\\?*\"<>|"))
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return "Einsatz \(cleaned).\(Self.fileExtension)"
    }
}

/// Ergebnis des Öffnens einer Einsatzdatei.
public struct MissionArchiveImport: Equatable, Sendable {
    public let missionID: MissionID
    public let imported: RemoteImportResult
    public let filesStored: Int
    /// Dateien mit falscher Prüfsumme (nicht übernommen).
    public let filesRejected: Int
}

public enum MissionArchiveError: Error, Equatable, Sendable {
    case unreadable
    case newerFormat
}

extension MissionArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable: "Die Datei ist keine gültige Einsatzdatei oder beschädigt."
        case .newerFormat: "Die Einsatzdatei stammt aus einer neueren App-Version. Bitte ELRD aktualisieren."
        }
    }
}

public extension MissionArchive {
    /// Übernimmt den Einsatz auf diesem Gerät.
    @MainActor
    func importInto(repository: any EntityRepository, clock: DeviceClock, files store: AttachmentFileStore?) throws -> MissionArchiveImport {
        let result = try RemoteChangeImporter(repository: repository, clock: clock).importEvents(events)
        var stored = 0
        var rejected = 0
        if let store {
            for file in files where !store.isIntact(file.attachment) {
                do {
                    try store.store(file.data, for: file.attachment)
                    stored += 1
                } catch {
                    rejected += 1
                }
            }
        }
        return MissionArchiveImport(missionID: missionID, imported: result, filesStored: stored, filesRejected: rejected)
    }
}

// MARK: - Endgültig löschen (Schritt 63)

/// Entfernt einen gelöschten Einsatz mit allen Daten, Ereignissen und Dateien
/// unwiderruflich vom Gerät (Datenschutz). Nur für Einsätze im Papierkorb.
public enum MissionPurge {
    public enum Failure: Error, Equatable, Sendable {
        /// Nur gelöschte Einsätze lassen sich endgültig entfernen.
        case notDeleted
    }

    /// Anzahl entfernter Dateien.
    @MainActor
    @discardableResult
    public static func purge(_ missionID: MissionID, repository: any EntityRepository, files store: AttachmentFileStore?) throws -> Int {
        guard let mission = try repository.entity(Mission.self, id: missionID.rawValue) else {
            throw CommandError.notFound(.mission)
        }
        guard mission.isDeleted else { throw Failure.notDeleted }
        let attachments = MissionAttachments.all(
            journal: try repository.entities(JournalEntry.self, in: missionID, includeDeleted: true),
            mapObjects: try repository.entities(MapObject.self, in: missionID, includeDeleted: true)
        )
        try repository.purgeMission(missionID)
        var removed = 0
        if let store {
            for attachment in attachments where (try? FileManager.default.removeItem(at: store.url(for: attachment))) != nil {
                removed += 1
            }
        }
        return removed
    }
}

extension MissionPurge.Failure: LocalizedError {
    public var errorDescription: String? {
        "Nur gelöschte Einsätze lassen sich endgültig entfernen."
    }
}
