import Foundation
import ELRDDomain

// MARK: - Kommunikationsplan (Schritt 112)

/// Funkkanäle, Rufnamen und Abschnitte auf einen Blick – aus Führungsstruktur,
/// Abschnittsleitungen und Einheiten. Zum Teilen als Text und zum Drucken.
public struct CommunicationPlan: Equatable, Sendable {
    /// Eine Zeile: Funktion bzw. Abschnitt mit Name, Rufname und Kanal.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let function: String
        public let name: String
        public let callsign: String
        public let channel: String
        /// Einheiten im Abschnitt (nur bei Abschnitten).
        public let units: [String]
    }

    /// Wer auf einem Kanal funkt.
    public struct Channel: Equatable, Sendable, Identifiable {
        public let name: String
        public let members: [String]
        public var id: String { name }
    }

    public let title: String
    public let leadership: [Entry]
    public let sections: [Entry]
    public let channels: [Channel]
    /// Einheiten ohne Abschnitt.
    public let unassignedUnits: [String]

    public var isEmpty: Bool { leadership.isEmpty && sections.isEmpty }

    public init(_ state: MissionState) {
        let mission = state.mission
        title = mission.reason.isEmpty ? "Einsatz" : mission.reason
        leadership = LeadershipRole.allCases.compactMap { role in
            let position = mission.position(role)
            guard !position.isEmpty else { return nil }
            return Entry(id: "role-\(role.rawValue)", function: role.shortName, name: position.name,
                         callsign: position.callsign, channel: position.radioChannel, units: [])
        }
        let units = MissionUnit.sorted(state.units.active)
        sections = MissionSection.sorted(state.sections.active).map { section in
            Entry(
                id: "section-\(section.id.rawValue.uuidString)",
                function: section.name,
                name: section.leaderName ?? "",
                callsign: section.leaderCallsign ?? "",
                channel: section.radioChannel ?? "",
                units: units.filter { $0.sectionID == section.id }.map(\.displayName)
            )
        }
        let sectionIDs = Set(state.sections.active.map(\.id))
        unassignedUnits = units.filter { $0.sectionID.map { !sectionIDs.contains($0) } ?? true }.map(\.displayName)

        // Kanäle in der Reihenfolge ihres ersten Auftretens (Führung zuerst).
        var order: [String] = []
        var members: [String: [String]] = [:]
        for entry in leadership + sections {
            let channel = entry.channel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !channel.isEmpty else { continue }
            if members[channel] == nil { order.append(channel) }
            let label = entry.callsign.isEmpty ? entry.function : "\(entry.function) (\(entry.callsign))"
            members[channel, default: []].append(label)
        }
        channels = order.map { Channel(name: $0, members: members[$0] ?? []) }
    }

    /// Text zum Teilen (Nachricht, Mail).
    public var text: String {
        var lines = ["Kommunikationsplan – \(title)"]
        if !channels.isEmpty {
            lines.append("")
            lines.append("Kanäle")
            for channel in channels {
                lines.append("\(channel.name): " + channel.members.joined(separator: ", "))
            }
        }
        if !leadership.isEmpty {
            lines.append("")
            lines.append("Führung")
            for entry in leadership { lines.append(Self.line(entry)) }
        }
        if !sections.isEmpty {
            lines.append("")
            lines.append("Abschnitte")
            for entry in sections {
                lines.append(Self.line(entry))
                if !entry.units.isEmpty { lines.append("  Einheiten: " + entry.units.joined(separator: ", ")) }
            }
        }
        if !unassignedUnits.isEmpty {
            lines.append("")
            lines.append("Ohne Abschnitt: " + unassignedUnits.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Druckfassung als einfache HTML-Tabelle (für den Druckdialog).
    public func html(printedAt: String) -> String {
        func esc(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func row(_ entry: Entry, units: Bool) -> String {
            var cells = [entry.function, entry.name, entry.callsign, entry.channel].map { "<td>\(esc($0.isEmpty ? "–" : $0))</td>" }
            if units { cells.append("<td>\(esc(entry.units.isEmpty ? "–" : entry.units.joined(separator: ", ")))</td>") }
            return "<tr>\(cells.joined())</tr>"
        }
        var html = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 11pt; }
        h1 { font-size: 18pt; margin-bottom: 2pt; } h2 { font-size: 13pt; margin: 14pt 0 4pt; }
        table { width: 100%; border-collapse: collapse; } th, td { border: 1px solid #888; padding: 4pt 6pt; text-align: left; vertical-align: top; }
        th { background: #eee; } .meta { color: #555; }
        </style></head><body>
        <h1>Kommunikationsplan – \(esc(title))</h1><div class="meta">Stand \(esc(printedAt))</div>
        """
        if !channels.isEmpty {
            html += "<h2>Kanäle</h2><table><tr><th>Kanal</th><th>Teilnehmer</th></tr>"
            html += channels.map { "<tr><td><b>\(esc($0.name))</b></td><td>\(esc($0.members.joined(separator: ", ")))</td></tr>" }.joined()
            html += "</table>"
        }
        if !leadership.isEmpty {
            html += "<h2>Führung</h2><table><tr><th>Funktion</th><th>Name</th><th>Rufname</th><th>Kanal</th></tr>"
            html += leadership.map { row($0, units: false) }.joined()
            html += "</table>"
        }
        if !sections.isEmpty {
            html += "<h2>Abschnitte</h2><table><tr><th>Abschnitt</th><th>Leitung</th><th>Rufname</th><th>Kanal</th><th>Einheiten</th></tr>"
            html += sections.map { row($0, units: true) }.joined()
            html += "</table>"
        }
        if !unassignedUnits.isEmpty {
            html += "<p><b>Ohne Abschnitt:</b> \(esc(unassignedUnits.joined(separator: ", ")))</p>"
        }
        return html + "</body></html>"
    }

    private static func line(_ entry: Entry) -> String {
        var parts = [entry.function]
        if !entry.name.isEmpty { parts.append(entry.name) }
        if !entry.callsign.isEmpty { parts.append("Rufname \(entry.callsign)") }
        if !entry.channel.isEmpty { parts.append("Kanal \(entry.channel)") }
        return parts.joined(separator: " · ")
    }
}
