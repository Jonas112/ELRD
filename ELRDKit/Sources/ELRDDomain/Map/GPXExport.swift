import Foundation

// MARK: - GPX für Garmin (Schritt 119)

/// Kartenobjekte als GPX 1.1 – das Format, das Garmin-Geräte (Handgeräte, inReach,
/// Navis über Garmin Explore/BaseCamp) direkt importieren.
///
/// - Kreis, Rechteck, Zeichnung (umgebendes Rechteck) und Fläche: geschlossener Track.
/// - Pfeil: offener Track (Startpunkt → Spitze).
/// - Taktisches Zeichen, Abschnitte, Einsatzort: Wegpunkte.
/// Keine Patientendaten – nur Geometrie und Bezeichnungen.
public enum GPXExport {
    /// Punkte, mit denen ein Kreis angenähert wird.
    public static let circleSegments = 48

    public struct Waypoint: Equatable, Sendable {
        public let name: String
        public let coordinate: GeoCoordinate
        public let description: String?
        /// Garmin-Symbolname, z. B. „Flag, Red“.
        public let symbol: String

        public init(name: String, coordinate: GeoCoordinate, description: String? = nil, symbol: String = "Flag, Blue") {
            self.name = name
            self.coordinate = coordinate
            self.description = description
            self.symbol = symbol
        }
    }

    public struct Track: Equatable, Sendable {
        public let name: String
        public let points: [GeoCoordinate]
        public let description: String?

        public init(name: String, points: [GeoCoordinate], description: String? = nil) {
            self.name = name
            self.points = points
            self.description = description
        }
    }

    /// Wegpunkt bzw. Track eines Kartenobjekts.
    public static func items(for object: MapObject) -> (waypoints: [Waypoint], tracks: [Track]) {
        let name = object.displayName
        let note = object.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = note.isEmpty ? nil : note
        if object.tacticalSign != nil {
            return ([Waypoint(name: name, coordinate: object.shape.center, description: description, symbol: "Flag, Red")], [])
        }
        let track: Track
        if let path = object.path {
            var points = path.points
            if path.kind == .polygon, let first = points.first { points.append(first) }
            track = Track(name: name, points: points, description: description ?? object.sizeText)
        } else {
            switch object.shape {
            case let .circle(center, radius):
                track = Track(name: name, points: circle(center: center, radiusMeters: radius), description: description ?? object.sizeText)
            case let .rectangle(bounds), let .drawing(bounds, _):
                track = Track(name: name, points: rectangle(bounds), description: description ?? object.sizeText)
            }
        }
        // Schritt 123: Beschriftung zusätzlich als Wegpunkt in der Mitte – Garmin-Geräte
        // zeigen Wegpunktnamen auf der Karte, Tracknamen meist nicht.
        let title = object.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ([], [track]) }
        let label = Waypoint(name: title, coordinate: labelPoint(for: object), description: description ?? object.sizeText, symbol: "Flag, Green")
        return ([label], [track])
    }

    /// Stelle der Beschriftung: Schwerpunkt der Fläche, Mitte von Kreis/Rechteck,
    /// beim Pfeil der Startpunkt.
    static func labelPoint(for object: MapObject) -> GeoCoordinate {
        if let path = object.path {
            switch path.kind {
            case .polygon:
                let count = Double(path.points.count)
                let latitude = path.points.map(\.latitude).reduce(0, +) / count
                let longitude = path.points.map(\.longitude).reduce(0, +) / count
                return GeoCoordinate(latitude: latitude, longitude: longitude) ?? object.shape.center
            case .arrow:
                return path.points.first ?? object.shape.center
            }
        }
        return object.shape.center
    }

    /// Ganze Lagekarte: Einsatzort, Abschnitte und alle Kartenobjekte.
    public static func document(
        title: String,
        missionCoordinate: GeoCoordinate?,
        sections: [MissionSection],
        objects: [MapObject],
        createdAt: Date
    ) -> String {
        var waypoints: [Waypoint] = []
        var tracks: [Track] = []
        if let missionCoordinate {
            waypoints.append(Waypoint(name: "Einsatzort", coordinate: missionCoordinate, description: title, symbol: "Flag, Red"))
        }
        for section in sections {
            guard let coordinate = section.coordinate else { continue }
            waypoints.append(Waypoint(name: section.name, coordinate: coordinate, description: "Abschnitt", symbol: "Flag, Blue"))
        }
        for object in objects {
            let items = items(for: object)
            waypoints += items.waypoints
            tracks += items.tracks
        }
        return xml(name: title, waypoints: waypoints, tracks: tracks, createdAt: createdAt)
    }

    /// Ein einzelnes Kartenobjekt.
    public static func document(for object: MapObject, createdAt: Date) -> String {
        let items = items(for: object)
        return xml(name: object.displayName, waypoints: items.waypoints, tracks: items.tracks, createdAt: createdAt)
    }

    /// Dateiname ohne Sonderzeichen, z. B. „Sperrzone.gpx“.
    public static func fileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        return (cleaned.isEmpty ? "Lagekarte" : String(cleaned.prefix(60))) + ".gpx"
    }

    // MARK: Geometrie

    static func circle(center: GeoCoordinate, radiusMeters: Double) -> [GeoCoordinate] {
        let perLatitude = 111_320.0
        let perLongitude = max(1, perLatitude * cos(center.latitude * .pi / 180))
        var points = (0..<circleSegments).compactMap { index -> GeoCoordinate? in
            let angle = Double(index) / Double(circleSegments) * 2 * .pi
            return GeoCoordinate(
                latitude: center.latitude + radiusMeters * cos(angle) / perLatitude,
                longitude: center.longitude + radiusMeters * sin(angle) / perLongitude
            )
        }
        if let first = points.first { points.append(first) }
        return points
    }

    static func rectangle(_ bounds: GeoBounds) -> [GeoCoordinate] {
        [
            (bounds.north, bounds.west), (bounds.north, bounds.east),
            (bounds.south, bounds.east), (bounds.south, bounds.west), (bounds.north, bounds.west),
        ].compactMap { GeoCoordinate(latitude: $0.0, longitude: $0.1) }
    }

    // MARK: XML

    static func xml(name: String, waypoints: [Waypoint], tracks: [Track], createdAt: Date) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="ELRD" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <metadata>",
            "    <name>\(escape(name))</name>",
            "    <time>\(timestamp(createdAt))</time>",
            "  </metadata>",
        ]
        for waypoint in waypoints {
            lines.append(#"  <wpt lat="\#(number(waypoint.coordinate.latitude))" lon="\#(number(waypoint.coordinate.longitude))">"#)
            lines.append("    <name>\(escape(waypoint.name))</name>")
            if let description = waypoint.description { lines.append("    <desc>\(escape(description))</desc>") }
            lines.append("    <sym>\(escape(waypoint.symbol))</sym>")
            lines.append("  </wpt>")
        }
        for track in tracks where track.points.count >= 2 {
            lines.append("  <trk>")
            lines.append("    <name>\(escape(track.name))</name>")
            if let description = track.description { lines.append("    <desc>\(escape(description))</desc>") }
            lines.append("    <trkseg>")
            for point in track.points {
                lines.append(#"      <trkpt lat="\#(number(point.latitude))" lon="\#(number(point.longitude))"/>"#)
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Punkt als Dezimaltrenner, 7 Nachkommastellen (≈ 1 cm).
    static func number(_ value: Double) -> String {
        String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
