import Foundation
import ELRDDomain

// MARK: - Kommunikationsplan (Schritte 112 und 126)

/// Kommunikationsplan nach FwDV/DV 800 („Informations- und Kommunikationstechnik
/// im Einsatz“, Anlage 1): Einsatzleitung, Führungsgruppe, Einsatzabschnitte mit
/// Auftrag, Rufname, Rufgruppe und Telefon, Rufgruppen, benachbarte Kräfte und
/// sonstige Stellen. Dazu der taktische Organisations-/Kommunikationsplan als
/// Organigramm. Daten aus „Führung und Kräfte“ und den Abschnittsleitungen.
public struct CommunicationPlan: Equatable, Sendable {
    /// Eine Stelle: Funktion, Abschnitt oder externe Stelle.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        /// Funktion („ELRD“) bzw. Abschnittsname.
        public let function: String
        /// Langform der Funktion („Einsatzleiter Rettungsdienst“), sonst leer.
        public let detail: String
        public let name: String
        public let callsign: String
        public let channel: String
        public let phone: String
        public let email: String
        /// Auftrag (nur Abschnitte).
        public let task: String
        /// Einheiten im Abschnitt (nur Abschnitte).
        public let units: [String]

        public init(id: String, function: String, detail: String = "", name: String = "", callsign: String = "", channel: String = "",
                    phone: String = "", email: String = "", task: String = "", units: [String] = []) {
            self.id = id
            self.function = function
            self.detail = detail
            self.name = name
            self.callsign = callsign
            self.channel = channel
            self.phone = phone
            self.email = email
            self.task = task
            self.units = units
        }

        public var isVacant: Bool { name.isEmpty && callsign.isEmpty }
    }

    /// Rufgruppe mit ihren Teilnehmern.
    public struct Channel: Equatable, Sendable, Identifiable {
        public let name: String
        public let members: [String]
        public var id: String { name }
    }

    public let title: String
    /// Einsatzleitung: ELRD, LNA, OrgL (besetzt).
    public let leadership: [Entry]
    /// Führungsgruppe/Führungsassistenz (DV 800: „Führungsstab/Führungsgruppe“).
    public let staff: [Entry]
    /// Einsatzabschnitte (EA).
    public let sections: [Entry]
    public let neighbouringForces: [Entry]
    public let otherOffices: [Entry]
    public let channels: [Channel]
    /// Einheiten ohne Abschnitt.
    public let unassignedUnits: [String]

    public var isEmpty: Bool { leadership.isEmpty && staff.isEmpty && sections.isEmpty && neighbouringForces.isEmpty && otherOffices.isEmpty }

    public init(_ state: MissionState) {
        let mission = state.mission
        title = mission.reason.isEmpty ? "Einsatz" : mission.reason
        func entry(_ role: LeadershipRole) -> Entry? {
            let position = mission.position(role)
            guard !position.isEmpty else { return nil }
            return Entry(id: "role-\(role.rawValue)", function: role.shortName, detail: role.displayName, name: position.name,
                         callsign: position.callsign, channel: position.radioChannel, phone: position.phone ?? "")
        }
        leadership = [LeadershipRole.einsatzleiter, .lna, .orgl].compactMap(entry)
        staff = [LeadershipRole.fuehrungsassistenz].compactMap(entry)
        let units = MissionUnit.sorted(state.units.active)
        sections = MissionSection.sorted(state.sections.active).map { section in
            Entry(
                id: "section-\(section.id.rawValue.uuidString)",
                function: section.name,
                name: section.leaderName ?? "",
                callsign: section.leaderCallsign ?? "",
                channel: section.radioChannel ?? "",
                phone: section.leaderPhone ?? "",
                task: section.task ?? "",
                units: units.filter { $0.sectionID == section.id }.map(\.displayName)
            )
        }
        let contacts = (mission.communicationContacts ?? []).map { contact in
            (contact.isNeighbouringForce,
             Entry(id: "contact-\(contact.id.uuidString)", function: contact.name, callsign: contact.callsign,
                   channel: contact.channel, phone: contact.phone, email: contact.email))
        }
        neighbouringForces = contacts.filter { $0.0 }.map(\.1)
        otherOffices = contacts.filter { !$0.0 }.map(\.1)
        let sectionIDs = Set(state.sections.active.map(\.id))
        unassignedUnits = units.filter { $0.sectionID.map { !sectionIDs.contains($0) } ?? true }.map(\.displayName)

        // Rufgruppen in der Reihenfolge ihres ersten Auftretens (Führung zuerst).
        var order: [String] = []
        var members: [String: [String]] = [:]
        for entry in leadership + staff + sections + neighbouringForces + otherOffices {
            let channel = entry.channel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !channel.isEmpty else { continue }
            if members[channel] == nil { order.append(channel) }
            let label = entry.callsign.isEmpty ? entry.function : "\(entry.function) (\(entry.callsign))"
            members[channel, default: []].append(label)
        }
        channels = order.map { Channel(name: $0, members: members[$0] ?? []) }
    }

    // MARK: Text

    /// Text zum Teilen (Nachricht, Mail).
    public var text: String {
        var lines = ["Kommunikationsplan – \(title)"]
        func block(_ heading: String, _ entries: [Entry]) {
            guard !entries.isEmpty else { return }
            lines.append("")
            lines.append(heading)
            for entry in entries {
                lines.append(Self.line(entry))
                if !entry.task.isEmpty { lines.append("  Auftrag: \(entry.task)") }
                if !entry.units.isEmpty { lines.append("  Einheiten: " + entry.units.joined(separator: ", ")) }
            }
        }
        if !channels.isEmpty {
            lines.append("")
            lines.append("Rufgruppen")
            for channel in channels {
                lines.append("\(channel.name): " + channel.members.joined(separator: ", "))
            }
        }
        block("Einsatzleitung", leadership)
        block("Führungsgruppe", staff)
        block("Einsatzabschnitte", sections)
        block("Benachbarte Kräfte", neighbouringForces)
        block("Sonstige Stellen", otherOffices)
        if !unassignedUnits.isEmpty {
            lines.append("")
            lines.append("Ohne Abschnitt: " + unassignedUnits.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ entry: Entry) -> String {
        var parts = [entry.function]
        if !entry.name.isEmpty { parts.append(entry.name) }
        if !entry.callsign.isEmpty { parts.append("Rufname \(entry.callsign)") }
        if !entry.channel.isEmpty { parts.append("Rufgruppe \(entry.channel)") }
        if !entry.phone.isEmpty { parts.append("Tel. \(entry.phone)") }
        if !entry.email.isEmpty { parts.append(entry.email) }
        return parts.joined(separator: " · ")
    }

    // MARK: Druck – Kommunikationsplan (DV 800, Anlage 1)

    /// Formular „Kommunikationsplan“ (Hochformat).
    /// - Parameters:
    ///   - printedAt: Stand (Datum/Uhrzeit).
    ///   - issuer: Dienststelle (Organisation aus den Einstellungen).
    public func html(printedAt: String, issuer: String = "") -> String {
        let clerk = (staff.first ?? leadership.first).map { $0.name } ?? ""
        var html = Self.head(landscape: false) + """
        <h1>Kommunikationsplan</h1>
        <table class="head"><tr>
        <td><span>Dienststelle</span>\(Self.cell(issuer))</td>
        <td><span>Einsatz</span>\(Self.cell(title))</td>
        <td><span>Stand (Datum/Uhrzeit)</span>\(Self.cell(printedAt))</td>
        <td><span>Sachbearbeiter</span>\(Self.cell(clerk))</td>
        </tr></table>
        """
        func table(_ heading: String, _ first: String, _ entries: [Entry], tasks: Bool = false, mail: Bool = false) {
            guard !entries.isEmpty else { return }
            var header = ["<th>\(first)</th>"]
            if tasks { header.append("<th>Auftrag</th>") }
            header += ["<th>Leiter / Name</th>", "<th>Rufname</th>", "<th>Rufgruppe</th>", "<th>Telefon / Mobil</th>"]
            if mail { header.append("<th>E-Mail</th>") }
            if tasks { header.append("<th>Kräfte</th>") }
            html += "<h2>\(Self.esc(heading))</h2><table><tr>\(header.joined())</tr>"
            for entry in entries {
                var cells = ["<td><b>\(Self.esc(entry.function))</b>\(entry.detail.isEmpty ? "" : "<br><small>\(Self.esc(entry.detail))</small>")</td>"]
                if tasks { cells.append("<td>\(Self.cell(entry.task))</td>") }
                cells += [entry.name, entry.callsign, entry.channel, entry.phone].map { "<td>\(Self.cell($0))</td>" }
                if mail { cells.append("<td>\(Self.cell(entry.email))</td>") }
                if tasks { cells.append("<td>\(Self.cell(entry.units.joined(separator: ", ")))</td>") }
                html += "<tr>\(cells.joined())</tr>"
            }
            html += "</table>"
        }
        table("Einsatzleitung", "Funktion", leadership)
        table("Führungsstab / Führungsgruppe", "Funktion", staff)
        table("Einsatzabschnitte (EA)", "EA", sections, tasks: true)
        if !channels.isEmpty {
            html += "<h2>Rufgruppen</h2><table><tr><th>Rufgruppe</th><th>Teilnehmer</th></tr>"
            html += channels.map { "<tr><td><b>\(Self.esc($0.name))</b></td><td>\(Self.esc($0.members.joined(separator: ", ")))</td></tr>" }.joined()
            html += "</table>"
        }
        table("Benachbarte Kräfte", "Stelle", neighbouringForces, mail: true)
        table("Sonstige Stellen", "Stelle", otherOffices, mail: true)
        if !unassignedUnits.isEmpty {
            html += "<p><b>Ohne Abschnitt:</b> \(Self.esc(unassignedUnits.joined(separator: ", ")))</p>"
        }
        return html + Self.foot("Kommunikationsplan nach FwDV/DV 800, Anlage 1")
    }

    // MARK: Druck – taktischer Organisations-/Kommunikationsplan

    /// Organigramm (Querformat): Einsatzleitung oben, Führungsgruppe daneben,
    /// darunter die Einsatzabschnitte; benachbarte Kräfte und sonstige Stellen unten.
    public func organisationChartHTML(printedAt: String, issuer: String = "") -> String {
        // Querformat A4: ca. 760 pt nutzbar; Kästen passen sich der Anzahl an.
        let count = max(1, sections.count)
        let width = min(170, max(84, 740 / count - 10))
        var html = Self.head(landscape: true, boxWidth: width) + """
        <h1>Taktischer Organisations- und Kommunikationsplan</h1>
        <div class="meta">\(Self.esc(title))\(issuer.isEmpty ? "" : " · \(Self.esc(issuer))") · Stand \(Self.esc(printedAt))</div>
        <div class="tree"><ul><li>
        """
        html += "<div class=\"box lead\">" + Self.boxHeader("Einsatzleitung")
        if leadership.isEmpty {
            html += "<div class=\"row muted\">nicht besetzt</div>"
        }
        for entry in leadership { html += Self.boxBody(entry, compact: true) }
        html += "</div>"
        if !staff.isEmpty {
            html += "<div class=\"staff\"><div class=\"box\">" + Self.boxHeader("Führungsgruppe")
            for entry in staff { html += Self.boxBody(entry, compact: true) }
            html += "</div></div>"
        }
        if !sections.isEmpty {
            html += "<ul>"
            for entry in sections {
                html += "<li><div class=\"box\">" + Self.boxHeader("EA \(entry.function)") + Self.boxBody(entry, compact: false) + "</div></li>"
            }
            html += "</ul>"
        }
        html += "</li></ul></div>"
        let external = neighbouringForces.map { ("Benachbarte Kräfte", $0) } + otherOffices.map { ("Sonstige Stelle", $0) }
        if !external.isEmpty {
            html += "<h2>Benachbarte Kräfte und sonstige Stellen</h2><div class=\"external\">"
            for (kind, entry) in external {
                html += "<div class=\"box dashed\">" + Self.boxHeader(entry.function, small: kind) + Self.boxBody(entry, compact: false) + "</div>"
            }
            html += "</div>"
        }
        if !channels.isEmpty {
            html += "<h2>Rufgruppen</h2><table><tr>"
            html += channels.map { "<th>\(Self.esc($0.name))</th>" }.joined()
            html += "</tr><tr>"
            html += channels.map { "<td>\(Self.esc($0.members.joined(separator: ", ")))</td>" }.joined()
            html += "</tr></table>"
        }
        return html + Self.foot("Taktischer Organisations-/Kommunikationsplan nach FwDV/DV 800, Anlage 1")
    }

    // MARK: HTML-Bausteine

    private static func head(landscape: Bool, boxWidth: Int = 150) -> String {
        """
        <html><head><meta charset="utf-8"><style>
        @page { size: A4 \(landscape ? "landscape" : "portrait"); }
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: \(landscape ? 8.5 : 10)pt; color: #111; }
        h1 { font-size: 16pt; margin: 0 0 4pt; } h2 { font-size: 11pt; margin: 12pt 0 4pt; }
        .meta { color: #444; margin-bottom: 6pt; }
        table { width: 100%; border-collapse: collapse; page-break-inside: auto; }
        th, td { border: 1px solid #777; padding: 3pt 5pt; text-align: left; vertical-align: top; }
        th { background: #e6e6e6; } small { color: #555; }
        table.head td { width: 25%; } table.head span { display: block; font-size: 7.5pt; color: #555; }
        .tree ul { padding: 14pt 0 0; margin: 0; position: relative; display: flex; justify-content: center; }
        .tree > ul { padding-top: 0; }
        .tree li { list-style: none; position: relative; padding: 14pt 4pt 0; display: flex; flex-direction: column; align-items: center; }
        .tree > ul > li { padding-top: 0; }
        .tree li::before, .tree li::after { content: ''; position: absolute; top: 0; right: 50%; border-top: 1.2px solid #222; width: 50%; height: 14pt; }
        .tree li::after { right: auto; left: 50%; border-left: 1.2px solid #222; }
        .tree li:only-child::before, .tree li:only-child::after, .tree > ul > li::before, .tree > ul > li::after { display: none; }
        .tree li:first-child::before, .tree li:last-child::after { border: 0 none; }
        .tree li:last-child::before { border-right: 1.2px solid #222; }
        .tree ul ul::before { content: ''; position: absolute; top: 0; left: 50%; border-left: 1.2px solid #222; height: 14pt; }
        .box { width: \(boxWidth)pt; border: 1.2px solid #222; border-radius: 4pt; text-align: left; background: #fff; page-break-inside: avoid; }
        .box.lead { width: \(max(boxWidth, 190))pt; border-width: 2px; }
        .box.dashed { border-style: dashed; }
        .box .title { background: #222; color: #fff; font-weight: bold; padding: 2pt 4pt; border-radius: 2pt 2pt 0 0; }
        .box .title small { color: #ddd; font-weight: normal; display: block; }
        .box .row { padding: 1pt 4pt; } .box .row:last-child { padding-bottom: 3pt; }
        .box .callsign { font-weight: bold; } .box .channel { display: inline-block; border: 1px solid #222; border-radius: 6pt; padding: 0 4pt; margin-top: 1pt; }
        .box .sep { border-top: 1px solid #bbb; margin-top: 2pt; }
        .muted { color: #666; }
        .staff { position: absolute; left: calc(50% + \(max(boxWidth, 190) / 2 + 24)pt); top: 0; }
        .staff::before { content: ''; position: absolute; left: -24pt; top: 14pt; width: 24pt; border-top: 1.2px dashed #222; }
        .external { display: flex; flex-wrap: wrap; gap: 6pt; }
        .footer { margin-top: 12pt; font-size: 7.5pt; color: #666; }
        </style></head><body>
        """
    }

    private static func foot(_ note: String) -> String {
        "<div class=\"footer\">\(esc(note)) · erstellt mit ELRD</div></body></html>"
    }

    private static func boxHeader(_ title: String, small: String = "") -> String {
        "<div class=\"title\">\(small.isEmpty ? "" : "<small>\(esc(small))</small>")\(esc(title))</div>"
    }

    private static func boxBody(_ entry: Entry, compact: Bool) -> String {
        var rows: [String] = []
        if compact {
            rows.append("<div class=\"row sep\"><b>\(esc(entry.function))</b> \(esc(entry.name))</div>")
        } else if !entry.name.isEmpty {
            rows.append("<div class=\"row\">Ltg.: \(esc(entry.name))</div>")
        }
        if !entry.callsign.isEmpty { rows.append("<div class=\"row callsign\">\(esc(entry.callsign))</div>") }
        if !entry.channel.isEmpty { rows.append("<div class=\"row\"><span class=\"channel\">\(esc(entry.channel))</span></div>") }
        if !entry.phone.isEmpty { rows.append("<div class=\"row\">Tel. \(esc(entry.phone))</div>") }
        if !entry.email.isEmpty { rows.append("<div class=\"row\">\(esc(entry.email))</div>") }
        if !entry.task.isEmpty { rows.append("<div class=\"row\"><i>Auftrag:</i> \(esc(entry.task))</div>") }
        if !entry.units.isEmpty {
            rows.append("<div class=\"row muted\">\(entry.units.count == 1 ? "1 Einheit" : "\(entry.units.count) Einheiten"): \(esc(entry.units.joined(separator: ", ")))</div>")
        }
        if !compact, entry.isVacant, entry.channel.isEmpty { rows.append("<div class=\"row muted\">Leitung nicht besetzt</div>") }
        return rows.joined()
    }

    static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func cell(_ text: String) -> String {
        text.isEmpty ? "–" : esc(text)
    }
}
