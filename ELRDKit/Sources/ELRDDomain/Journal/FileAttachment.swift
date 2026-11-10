import Foundation

/// Art einer Anhangsdatei. Rohwerte 1–3 wie ELRDRG (`DocumentationType`).
public enum AttachmentKind: Int, CaseIterable, Codable, Sendable, DisplayNamed {
    case audio = 1
    case photo = 2
    case video = 3
    /// Freihandzeichnung auf der Lagekarte (PNG mit Transparenz).
    case drawing = 4

    public var displayName: String {
        switch self {
        case .audio: "Audio"
        case .photo: "Foto"
        case .video: "Video"
        case .drawing: "Zeichnung"
        }
    }

    /// Dateiendung, unter der die Datei abgelegt wird.
    public var fileExtension: String {
        switch self {
        case .audio: "m4a"
        case .photo: "jpg"
        case .video: "mov"
        case .drawing: "png"
        }
    }
}

/// Verweis auf eine Binärdatei (Foto, Audio, Zeichnung).
///
/// Die Datei liegt im App-Container, die Datenbank speichert nur diesen Verweis
/// mit Prüfsumme (siehe docs/ARCHITEKTUR.md, Abschnitt Persistenz). Die Prüfsumme
/// erlaubt später, beim Synchronisieren fehlende oder beschädigte Dateien zu erkennen.
public struct FileAttachment: Identifiable, Hashable, Codable, Sendable {
    public let id: AttachmentID
    public let kind: AttachmentKind
    /// Größe in Bytes.
    public let byteCount: Int
    /// SHA-256 der Datei als Hex-String (64 Zeichen, Kleinbuchstaben).
    public let sha256: String
    public let createdAt: Date
    /// Abspieldauer in Sekunden (Audio, Video).
    public let duration: TimeInterval?
    /// Pixelmaße (Foto, Video, Zeichnung).
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// Aufnahmeort eines Fotos (Schritt 111, aus den Bilddaten oder dem Standort);
    /// `nil` = unbekannt. Erscheint als Marker auf der Lagekarte.
    public let coordinate: GeoCoordinate?

    public init(
        id: AttachmentID = AttachmentID(),
        kind: AttachmentKind,
        byteCount: Int,
        sha256: String,
        createdAt: Date,
        duration: TimeInterval? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        coordinate: GeoCoordinate? = nil
    ) {
        self.id = id
        self.kind = kind
        self.byteCount = max(byteCount, 0)
        self.sha256 = sha256.lowercased()
        self.createdAt = createdAt
        self.duration = duration.map { max($0, 0) }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.coordinate = coordinate
    }

    /// Dateiname im Anhangsordner, abgeleitet aus Kennung und Art – nie aus Nutzereingaben.
    public var fileName: String {
        "\(id.rawValue.uuidString.lowercased()).\(kind.fileExtension)"
    }

    /// Ob die Prüfsumme formal gültig ist (64 Hex-Zeichen).
    public var hasValidChecksum: Bool {
        sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Dateien eines Einsatzes (Schritt 55)

public extension MapShape {
    /// Datei der Form (nur Freihandzeichnungen).
    var attachment: FileAttachment? {
        if case let .drawing(_, image) = self { image } else { nil }
    }
}

public enum MissionAttachments {
    /// Alle Dateien, auf die Tagebuch und Lagekarte verweisen (auch gelöschte
    /// Einträge – sie lassen sich wiederherstellen). Jede Prüfsumme einmal.
    public static func all(journal: [JournalEntry], mapObjects: [MapObject]) -> [FileAttachment] {
        var seen = Set<String>()
        let files = journal.flatMap(\.attachments) + mapObjects.compactMap(\.shape.attachment)
        return files.filter { seen.insert($0.id.rawValue.uuidString).inserted }
    }
}
