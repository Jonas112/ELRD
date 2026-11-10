import Foundation
import ELRDDomain

/// Schritt 119: GPX-Datei für Garmin-Geräte im temporären Ordner ablegen und den
/// Pfad zum Teilen liefern (AirDrop, Dateien, Mail, Garmin Explore …).
enum GPXSharing {
    static func file(named title: String, contents: String) throws -> ExportedFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gpx", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(GPXExport.fileName(title))
        try Data(contents.utf8).write(to: url, options: .atomic)
        return ExportedFile(url: url)
    }
}
