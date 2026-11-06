import Foundation
import UIKit
import ELRDDomain

/// Kapitel „Einsatzdaten“ (Schritt 41): Stammdaten des Einsatzes, Kennzahlen,
/// Lagekarte.
enum MissionInfoChapter {
    static func blocks(_ input: ReportInput, options: ReportChapterOptions, theme: ReportTheme) -> [ReportBlock] {
        let mission = input.mission
        var pairs: [ReportKeyValue] = [ReportKeyValue("Einsatz", mission.displayNumber())]
        if let dispatch = mission.dispatchNumber, !dispatch.isEmpty { pairs.append(ReportKeyValue("Einsatznummer ILS", dispatch)) }
        if let type = mission.type { pairs.append(ReportKeyValue("Einsatzart", type.displayName)) }
        pairs.append(ReportKeyValue("Einsatzgrund", mission.reason))
        pairs.append(ReportKeyValue("Einsatzort", mission.location))
        if let coordinate = mission.coordinate { pairs.append(ReportKeyValue("Koordinaten", ReportFormat.coordinate(coordinate))) }
        pairs.append(ReportKeyValue("Beginn", ReportFormat.dateTime(mission.startedAt)))
        pairs.append(ReportKeyValue("Ende", mission.endedAt.map(ReportFormat.dateTime) ?? "läuft noch"))
        pairs.append(ReportKeyValue("Dauer", ReportFormat.duration(mission.duration(now: input.createdAt))))
        if let commander = mission.commanderID {
            pairs.append(ReportKeyValue("Einsatzleiter", input.people[commander] ?? "–"))
        }
        if mission.odometerStart != nil || mission.odometerEnd != nil {
            let start = mission.odometerStart.map { "\($0)" } ?? "–"
            let end = mission.odometerEnd.map { "\($0)" } ?? "–"
            let driven = mission.distanceDriven.map { " (\($0) km gefahren)" } ?? ""
            pairs.append(ReportKeyValue("Kilometerstand", "\(start) – \(end)\(driven)"))
        }

        var blocks: [ReportBlock] = [.heading(ReportChapter.Kind.missionInfo.displayName, level: 1), .keyValues(pairs)]
        if options.showsSummary {
            blocks.append(.heading("Lage in Zahlen", level: 2))
            blocks.append(.metrics(triageMetrics(input.patients, theme: theme)))
            blocks.append(.paragraph(statusLine(input.patients), style: .muted))
        }
        if options.showsMapImage, let map = mapImage(input) {
            blocks.append(.heading("Lagekarte", level: 2))
            blocks.append(.image(map.image, caption: map.caption, maxHeight: 340))
        }
        return blocks
    }

    /// Gesamt und SK 1–3 immer, die übrigen Kategorien nur, wenn vorhanden.
    static func triageMetrics(_ patients: [Patient], theme: ReportTheme) -> [ReportMetric] {
        var metrics = [ReportMetric(value: "\(patients.count)", label: "Patienten")]
        let order: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet, .unverletzt, .verstorben]
        for category in order {
            let count = patients.filter { $0.triage == category }.count
            guard count > 0 || [.sk1, .sk2, .sk3].contains(category) else { continue }
            metrics.append(ReportMetric(
                value: "\(count)",
                label: category.shortName,
                fill: theme.showsTriageColors ? category.color : nil,
                textColor: theme.showsTriageColors ? category.color.contrastingTextColor : nil
            ))
        }
        return metrics
    }

    static func statusLine(_ patients: [Patient]) -> String {
        let parts = PatientStatus.allCases.compactMap { status -> String? in
            let count = patients.filter { $0.status == status }.count
            return count > 0 ? "\(count) \(status.displayName.lowercased())" : nil
        }
        return parts.isEmpty ? "Keine Patienten erfasst." : "Stand: " + parts.joined(separator: " · ")
    }

    /// Vorschaubild des Einsatzes, sonst der letzte Kartenausschnitt.
    static func mapImage(_ input: ReportInput) -> (image: CGImage, caption: String)? {
        let snapshots = JournalEntry.chronological(input.journal).filter { $0.origin == .mapSnapshot && $0.firstImage != nil }
        let chosen = input.journal.first { $0.isMissionThumbnail && $0.firstImage != nil } ?? snapshots.last
        guard let entry = chosen, let file = entry.firstImage,
              let data = input.imageData(file), let image = UIImage(data: data)?.cgImage else { return nil }
        return (image, "Tagebucheintrag \(entry.number), \(ReportFormat.time(entry.occurredAt)) Uhr")
    }
}
