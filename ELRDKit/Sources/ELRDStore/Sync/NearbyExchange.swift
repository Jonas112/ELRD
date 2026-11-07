import Foundation
import ELRDDomain
import ELRDSync
import ELRDPersistence

/// Nachrichten beim Abgleich zwischen iPads vor Ort (Schritt 66). Der Transport
/// (MultipeerConnectivity) liegt in ELRDFeatures; hier steht nur, *was* gesendet
/// wird – damit es sich ohne Geräte testen lässt.
public enum NearbyMessage: Codable, Sendable, Equatable {
    /// Alle Ereignisse des Einsatzes (Archiv ohne Dateien).
    case events(Data)
    /// Diese Dateien (Prüfsummen) fehlen mir – bitte schicken.
    case wantFiles([String])
    /// Eine Datei samt Verweis.
    case file(FileAttachment, Data)

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> NearbyMessage { try JSONDecoder().decode(NearbyMessage.self, from: data) }
}

/// Ablauf auf einem Gerät: eigenen Stand schicken, fremden übernehmen, fehlende
/// Dateien anfordern und liefern. Jede Seite macht dasselbe; doppelte Ereignisse
/// und Dateien ändern nichts.
@MainActor
public final class NearbyExchange {
    public struct Progress: Equatable, Sendable {
        public var importedEvents = 0
        public var changedEntities = 0
        public var filesReceived = 0
        public var filesSent = 0
        public var filesRejected = 0

        public init() {}
    }

    public let missionID: MissionID
    private let repository: any EntityRepository
    private let clock: DeviceClock
    private let files: AttachmentFileStore?
    public private(set) var progress = Progress()

    public init(missionID: MissionID, repository: any EntityRepository, clock: DeviceClock, files: AttachmentFileStore?) {
        self.missionID = missionID
        self.repository = repository
        self.clock = clock
        self.files = files
    }

    /// Erste Nachricht nach dem Verbinden (und bei „Erneut abgleichen“);
    /// `nil`, wenn der Einsatz hier noch nicht existiert (Gerät übernimmt ihn erst).
    public func snapshot() throws -> NearbyMessage? {
        guard try repository.entity(Mission.self, id: missionID.rawValue) != nil else { return nil }
        let archive = try MissionArchive.make(mission: missionID, repository: repository, files: nil)
        return .events(try archive.encoded())
    }

    /// Verarbeitet eine Nachricht; Rückgabe: Antworten an dasselbe Gerät.
    public func handle(_ message: NearbyMessage) throws -> [NearbyMessage] {
        switch message {
        case .events(let data):
            let archive = try MissionArchive.decode(data)
            guard archive.missionID == missionID else { return [] }
            let result = try archive.importInto(repository: repository, clock: clock, files: nil)
            progress.importedEvents += result.imported.newEvents
            progress.changedEntities += result.imported.changedEntities
            let missing = try missingFiles()
            return missing.isEmpty ? [] : [.wantFiles(missing.map(\.sha256))]

        case .wantFiles(let hashes):
            guard let files else { return [] }
            let wanted = Set(hashes)
            var replies: [NearbyMessage] = []
            var sent = Set<String>()
            for attachment in try attachments() where wanted.contains(attachment.sha256) && !sent.contains(attachment.sha256) {
                guard files.isIntact(attachment), let data = files.data(for: attachment) else { continue }
                replies.append(.file(attachment, data))
                sent.insert(attachment.sha256)
            }
            progress.filesSent += replies.count
            return replies

        case .file(let attachment, let data):
            guard let files else { return [] }
            // Alle Verweise mit derselben Prüfsumme bedienen (gleiches Foto in zwei Einträgen).
            let targets = try attachments().filter { $0.sha256 == attachment.sha256 && !files.isIntact($0) }
            do {
                for target in targets.isEmpty ? [attachment] : targets {
                    try files.store(data, for: target)
                }
                progress.filesReceived += 1
            } catch {
                progress.filesRejected += 1
            }
            return []
        }
    }

    /// Dateien, auf die der Einsatz verweist, die hier noch fehlen.
    public func missingFiles() throws -> [FileAttachment] {
        guard let files else { return [] }
        var seen = Set<String>()
        return try attachments().filter { !files.isIntact($0) && seen.insert($0.sha256).inserted }
    }

    private func attachments() throws -> [FileAttachment] {
        MissionAttachments.all(
            journal: try repository.entities(JournalEntry.self, in: missionID, includeDeleted: true),
            mapObjects: try repository.entities(MapObject.self, in: missionID, includeDeleted: true)
        )
    }
}
