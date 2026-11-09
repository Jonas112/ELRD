import Foundation
import ELRDDomain

// MARK: - Checkliste (Schritt 76)

public extension MissionState {
    /// Abgehakte Punkte mit Zeitpunkt (frühester Haken je Punkt).
    var checkedItems: [String: JournalEntry] {
        var result: [String: JournalEntry] = [:]
        for entry in journal.active where entry.category == .checklist {
            guard let item = entry.checklistItemID else { continue }
            if let existing = result[item], existing.occurredAt <= entry.occurredAt { continue }
            result[item] = entry
        }
        return result
    }
}

/// Hakt einen Punkt ab: Tagebucheintrag „Checkliste: …“. Haken zwei Geräte
/// gleichzeitig ab, entstehen zwei Einträge – der Punkt bleibt einfach abgehakt.
public struct CheckChecklistItem: MissionCommand {
    public let item: ChecklistItem

    public init(_ item: ChecklistItem) {
        self.item = item
    }

    @discardableResult
    public func execute(_ draft: inout MissionDraft) throws -> JournalEntry {
        if let existing = draft.all(JournalEntry.self).first(where: {
            !$0.isDeleted && $0.category == .checklist && $0.checklistItemID == item.id
        }) {
            return existing
        }
        let entry = try draft.addJournalEntry(text: "Checkliste: \(item.title) ✓", origin: .manual)
        let itemID = item.id
        let updated = try draft.update(JournalEntry.self, id: entry.id) {
            $0.category = .checklist
            $0.checklistItemID = itemID
        }
        draft.log(.journal, "Checkliste: \(item.title) erledigt", subject: .journalEntry(entry.id))
        return updated
    }
}

/// Nimmt einen Haken zurück (alle Einträge dieses Punkts, auch von anderen Geräten).
public struct UncheckChecklistItem: MissionCommand {
    public let itemID: String

    public init(_ itemID: String) {
        self.itemID = itemID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let entries = draft.all(JournalEntry.self).filter {
            !$0.isDeleted && $0.category == .checklist && $0.checklistItemID == itemID
        }
        for entry in entries {
            try draft.delete(JournalEntry.self, id: entry.id)
            draft.log(.journal, "Checkliste: Haken zurückgenommen", subject: .journalEntry(entry.id))
        }
    }
}

// MARK: - Übergabe an die Ablösung (Schritt 75)

public enum HandoverReport {
    /// Übergabebericht: Lagemeldung plus Führung, offene Transporte, Nachforderungen
    /// und noch offene Punkte der Checkliste.
    public static func text(
        for state: MissionState,
        checklist: ChecklistTemplate,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        var parts = [SituationReport.text(for: state, now: now, calendar: calendar)]

        let leaders = (state.mission.leadership ?? []).map { position in
            let reach = [position.callsign, position.radioChannel].filter { !$0.isEmpty }.joined(separator: ", ")
            return "\(position.role.shortName): \(position.name.isEmpty ? "–" : position.name)\(reach.isEmpty ? "" : " (\(reach))")"
        }
        let sectionLeaders = state.activeSections.compactMap { section -> String? in
            guard section.leaderName != nil || section.radioChannel != nil else { return nil }
            let reach = [section.leaderCallsign, section.radioChannel].compactMap { $0 }.joined(separator: ", ")
            return "\(section.name): \(section.leaderName ?? "–")\(reach.isEmpty ? "" : " (\(reach))")"
        }
        if !leaders.isEmpty || !sectionLeaders.isEmpty {
            parts.append("Führung:\n" + (leaders + sectionLeaders).map { "– \($0)" }.joined(separator: "\n"))
        }

        let board = TransportBoard.columns(state)
        let waiting = board[.waiting] ?? []
        if !waiting.isEmpty {
            let list = waiting.map { patient in
                "– \(patient.number) \(patient.triage.shortName), wartet seit \(max(0, Int(now.timeIntervalSince(patient.metadata.createdAt) / 60))) min"
            }
            parts.append("Warten auf Transport (Reihenfolge):\n" + list.joined(separator: "\n"))
        }
        let assigned = board[.assigned] ?? []
        if !assigned.isEmpty {
            let names = Dictionary(uniqueKeysWithValues: state.units.map { ($0.id, $0.displayName) })
            let list = assigned.map { patient in
                let units = patient.unitIDs.compactMap { names[$0] }.joined(separator: ", ")
                let target = patient.destination.map { " → \($0.name)" } ?? ""
                return "– \(patient.number) \(patient.triage.shortName): \(units)\(target)"
            }
            parts.append("Eingeteilt, noch nicht abgefahren:\n" + list.joined(separator: "\n"))
        }

        let overloaded = HospitalDistribution.loads(state).filter { !$0.overloadedTriages.isEmpty }
        if !overloaded.isEmpty {
            parts.append("Kliniken über Kontingent: " + overloaded.map(\.name).joined(separator: ", "))
        }

        let checked = state.checkedItems
        let open = checklist.items.filter { checked[$0.id] == nil }
        if !open.isEmpty {
            parts.append("Checkliste offen:\n" + open.map { "– \($0.title)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Übergibt die Einsatzleitung: neuer Einsatzleiter, Eintrag im Tagebuch mit dem Bericht.
public struct HandOverMission: MissionCommand {
    public let newCommanderID: UserID?
    public let newCommanderName: String
    public let report: String

    public init(newCommanderID: UserID?, newCommanderName: String, report: String) {
        self.newCommanderID = newCommanderID
        self.newCommanderName = newCommanderName.trimmed
        self.report = report.trimmed
    }

    @discardableResult
    public func execute(_ draft: inout MissionDraft) throws -> JournalEntry {
        guard !newCommanderName.isEmpty else { throw CommandError.invalid("Wer übernimmt? Bitte Namen angeben.") }
        let previous = draft.mission.position(.einsatzleiter)
        let id = newCommanderID
        let name = newCommanderName
        _ = try draft.updateMission { mission in
            if let id { mission.commanderID = id }
            var position = mission.position(.einsatzleiter)
            position.name = name
            mission.setPosition(position)
        }
        let from = previous.name.isEmpty ? draft.context.session.displayName : previous.name
        var text = "Übergabe der Einsatzleitung von \(from) an \(name)."
        if !report.isEmpty { text += "\n\n" + report }
        let entry = try draft.addJournalEntry(text: text, origin: .manual)
        let updated = try draft.update(JournalEntry.self, id: entry.id) { $0.category = .handover }
        draft.log(.mission, "Einsatzleitung an \(name) übergeben", subject: .mission(draft.missionID))
        return updated
    }
}

// MARK: - Einsatzende-Prüfung (Schritt 104)

/// Was vor „Einsatz beenden“ noch offen ist. Nur Hinweise – beenden geht trotzdem
/// (Vorgabe Jonas).
public enum MissionClosingCheck {
    public static func warnings(for state: MissionState, checklist: ChecklistTemplate) -> [String] {
        var warnings: [String] = []
        let patients = state.patients.active
        let onScene = patients.filter { $0.outcome == nil && $0.triage != .verstorben }
        if !onScene.isEmpty {
            warnings.append(onScene.count == 1
                ? "1 Patient ist noch nicht abtransportiert oder entlassen."
                : "\(onScene.count) Patienten sind noch nicht abtransportiert oder entlassen.")
        }
        let untriaged = patients.filter { $0.triage == .ungesichtet }.count
        if untriaged > 0 {
            warnings.append(untriaged == 1 ? "1 Patient ist ungesichtet." : "\(untriaged) Patienten sind ungesichtet.")
        }
        let placeholders = state.activeUnits.filter(\.isPlaceholder).count
        if placeholders > 0 {
            warnings.append(placeholders == 1
                ? "1 angeforderte Einheit ohne Fahrzeug – bei der ILS abbestellen?"
                : "\(placeholders) angeforderte Einheiten ohne Fahrzeug – bei der ILS abbestellen?")
        }
        let awaited = state.activeUnits.filter { !$0.isPlaceholder && $0.isAwaitingArrival }.count
        if awaited > 0 {
            warnings.append(awaited == 1 ? "1 Einheit wird noch erwartet." : "\(awaited) Einheiten werden noch erwartet.")
        }
        let open = checklist.items.filter { state.checkedItems[$0.id] == nil }.count
        if open > 0 {
            warnings.append(open == 1 ? "Checkliste: 1 Punkt offen." : "Checkliste: \(open) Punkte offen.")
        }
        let unread = state.unreadMessageCount
        if unread > 0 {
            warnings.append(unread == 1 ? "1 Nachricht ist nicht gelesen." : "\(unread) Nachrichten sind nicht gelesen.")
        }
        return warnings
    }
}
