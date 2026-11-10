import Foundation
import ELRDDomain

// MARK: - Automatische Lagebilder (Schritt 109)

/// Lagebild im Takt: Text mit SK-Zahlen, Transporten und Einheiten, dazu (wenn ein
/// Einsatzort bekannt ist) ein Kartenbild. Landet als automatischer Eintrag im
/// Tagebuch – so lässt sich der Verlauf später Bild für Bild nachvollziehen (E114).
public enum SituationSnapshot {
    /// Zeitpunkt des letzten Lagebilds.
    public static func latest(in journal: [JournalEntry]) -> Date? {
        journal.active.filter { $0.isSituationSnapshot == true }.map(\.occurredAt).max()
    }

    /// Fällig, wenn seit dem letzten Lagebild (sonst seit Einsatzbeginn) der Takt
    /// vergangen ist. Abgeschlossene Einsätze bekommen keine Lagebilder.
    public static func isDue(_ state: MissionState, intervalMinutes: Int, now: Date) -> Bool {
        guard intervalMinutes > 0, !state.mission.isClosed else { return false }
        let base = latest(in: state.journal) ?? state.mission.startedAt
        return now.timeIntervalSince(base) >= TimeInterval(intervalMinutes * 60)
    }

    /// Nur ein Gerät erstellt Lagebilder: im geteilten Einsatz die Einsatzleitung,
    /// sonst das eigene Gerät. So entstehen keine doppelten Einträge.
    public static func isResponsible(_ mission: Mission, userID: UserID?) -> Bool {
        guard let commander = mission.commanderID, !(mission.participants ?? []).isEmpty else { return true }
        return commander == userID
    }

    /// Text des Lagebilds (ohne Namen, nur Zahlen).
    public static func text(_ state: MissionState, openItemCount: Int? = nil, now: Date, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        let minutes = max(0, Int(now.timeIntervalSince(state.mission.startedAt) / 60))
        lines.append("Lagebild \(timeText(now, timeZone: timeZone)) Uhr – Laufzeit \(durationText(minutes))")

        let patients = state.patients.active
        let onSite = patients.filter { $0.outcome == nil }
        let order: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet, .unverletzt, .verstorben]
        let counts = order.compactMap { triage -> String? in
            let count = onSite.filter { $0.triage == triage }.count
            guard count > 0 else { return nil }
            return "\(label(triage)): \(count)"
        }
        var patientLine = "Patienten: \(patients.count)"
        if !counts.isEmpty { patientLine += " – vor Ort " + counts.joined(separator: " · ") }
        lines.append(patientLine)

        let transported = patients.filter { $0.status == .inTransport }.count
        let released = patients.filter { $0.status == .released }.count
        let destination = onSite.filter { $0.destination != nil }.count
        var flow: [String] = []
        if destination > 0 { flow.append("Zielklinik zugewiesen \(destination)") }
        if transported > 0 { flow.append("abtransportiert \(transported)") }
        if released > 0 { flow.append("vor Ort entlassen \(released)") }
        if !flow.isEmpty { lines.append("Transporte: " + flow.joined(separator: " · ")) }

        let units = state.units.active
        let placeholders = units.filter(\.isPlaceholder).count
        let awaiting = units.filter { !$0.isPlaceholder && $0.isAwaitingArrival }.count
        let present = units.count - placeholders - awaiting
        var unitParts = ["\(present) vor Ort"]
        if awaiting > 0 { unitParts.append("\(awaiting) auf Anfahrt") }
        if placeholders > 0 { unitParts.append("\(placeholders) angefordert") }
        lines.append("Einheiten: " + unitParts.joined(separator: " · "))

        if let openItemCount {
            lines.append(openItemCount == 0 ? "Keine offenen Punkte" : "Offene Punkte: \(openItemCount)")
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ triage: Sichtungskategorie) -> String {
        switch triage {
        case .sk1, .sk2, .sk3: triage.shortName
        default: triage.displayName.lowercased()
        }
    }

    private static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func durationText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%d:%02d h", minutes / 60, minutes % 60)
    }
}

/// Legt ein Lagebild im Tagebuch an (Schritt 109). Liegt das letzte Lagebild weniger
/// als `minimumGap` zurück (z. B. von einem anderen Gerät), passiert nichts.
public struct AddSituationSnapshot: MissionCommand {
    public let text: String
    public let image: FileAttachment?
    public let minimumGap: TimeInterval

    public init(text: String, image: FileAttachment? = nil, minimumGap: TimeInterval = 0) {
        self.text = text
        self.image = image
        self.minimumGap = minimumGap
    }

    @discardableResult
    public func execute(_ draft: inout MissionDraft) throws -> JournalEntry? {
        if let image, image.kind != .photo { throw CommandError.invalid("Ein Lagebild muss ein Bild sein.") }
        let now = draft.context.now
        if minimumGap > 0, let last = SituationSnapshot.latest(in: draft.all(JournalEntry.self)), now.timeIntervalSince(last) < minimumGap {
            return nil
        }
        let entry = try draft.addJournalEntry(
            text: text,
            origin: image == nil ? .automatic : .mapSnapshot,
            attachments: image.map { [$0] } ?? []
        )
        let updated = try draft.update(JournalEntry.self, id: entry.id) { $0.isSituationSnapshot = true }
        draft.log(.journal, "Lagebild als Tagebucheintrag \(entry.number) gespeichert", subject: .journalEntry(entry.id))
        return updated
    }
}
