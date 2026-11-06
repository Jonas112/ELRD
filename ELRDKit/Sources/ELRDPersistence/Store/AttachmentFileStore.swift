import Foundation
import CryptoKit
import ELRDDomain

/// Ablage für Binärdateien (Zeichnungen, Fotos, Audio) im App-Container. Die
/// Datenbank speichert nur den Verweis `FileAttachment` mit Prüfsumme (ARCHITEKTUR.md).
/// Dateinamen kommen aus der Kennung, nie aus Nutzereingaben.
public final class AttachmentFileStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/ELRD/Attachments`.
    public static func standard(fileManager: FileManager = .default) throws -> AttachmentFileStore {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AttachmentFileStore(directory: support.appendingPathComponent("ELRD/Attachments", isDirectory: true))
    }

    /// Eigener Ordner im temporären Verzeichnis (Beispieldaten, Tests).
    public static func temporary() -> AttachmentFileStore {
        AttachmentFileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ELRD-Attachments-\(UUID().uuidString)", isDirectory: true))
    }

    /// Speichert die Datei geschützt (bis zur ersten Entsperrung verschlüsselt) und
    /// gibt den Verweis zurück.
    public func save(
        _ data: Data,
        kind: AttachmentKind,
        createdAt: Date,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: TimeInterval? = nil
    ) throws -> FileAttachment {
        let attachment = FileAttachment(
            kind: kind,
            byteCount: data.count,
            sha256: Self.sha256(data),
            createdAt: createdAt,
            duration: duration,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url(for: attachment), options: options)
        return attachment
    }

    public func url(for attachment: FileAttachment) -> URL {
        directory.appendingPathComponent(attachment.fileName)
    }

    /// Inhalt der Datei; `nil`, wenn sie (noch) fehlt, z. B. vor dem Abgleich.
    public func data(for attachment: FileAttachment) -> Data? {
        try? Data(contentsOf: url(for: attachment))
    }

    /// Datei vorhanden und Prüfsumme stimmt.
    public func isIntact(_ attachment: FileAttachment) -> Bool {
        data(for: attachment).map { Self.sha256($0) == attachment.sha256 } ?? false
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
