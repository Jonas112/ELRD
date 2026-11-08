import Foundation
import ELRDDomain

/// Verbleibsliste als PDF (Schritt 93) – für Personenauskunftsstelle, Polizei,
/// Angehörigenbetreuung. Enthält Namen, daher mit Hinweis.
public enum WhereaboutsReport {
    public static func pdf(
        mission: Mission,
        entries: [PatientWhereabouts],
        createdAt: Date,
        createdBy: String,
        theme: ReportTheme = ReportTheme()
    ) -> Data {
        PDFReportRenderer.render(blocks(entries: entries, createdAt: createdAt), theme: theme, info: ReportPageInfo(
            title: mission.isExerciseMission ? "ÜBUNG – Verbleibsliste" : "Verbleibsliste",
            subtitle: "Einsatz \(mission.displayNumber()) · \(mission.title)",
            footer: "Erstellt \(ReportFormat.dateTime(createdAt))" + (createdBy.isEmpty ? "" : " von \(createdBy)") + " · ELRD",
            author: createdBy
        ))
    }

    static func blocks(entries: [PatientWhereabouts], createdAt: Date) -> [ReportBlock] {
        var blocks: [ReportBlock] = [
            .heading("Verbleibsliste", level: 1),
            .paragraph("Stand \(ReportFormat.dateTime(createdAt)) · \(entries.count) Patienten. Enthält personenbezogene Daten – nur an berechtigte Stellen weitergeben.", style: .muted),
        ]
        guard !entries.isEmpty else {
            blocks.append(.paragraph("Keine Patienten erfasst."))
            return blocks
        }
        let rows = entries.map { entry -> [ReportTable.Cell] in
            [
                ReportTable.Cell(entry.number, isBold: true),
                ReportTable.Cell(entry.tagNumber ?? ""),
                ReportTable.Cell(entry.name.isEmpty ? "unbekannt" : entry.name),
                ReportTable.Cell([entry.birth, entry.gender == .unklar ? "" : entry.gender.displayName].filter { !$0.isEmpty }.joined(separator: ", ")),
                ReportTable.Cell(entry.triage.shortName, fill: entry.triage.color, textColor: entry.triage.color.contrastingTextColor),
                ReportTable.Cell(entry.detail.isEmpty ? entry.whereabouts : "\(entry.whereabouts) – \(entry.detail)"),
            ]
        }
        blocks.append(.table(ReportTable(
            columns: [
                ReportTable.Column("Nr.", width: .fixed(40)),
                ReportTable.Column("Karte", width: .fixed(64)),
                ReportTable.Column("Name", width: .flexible(1.3)),
                ReportTable.Column("Geb./Alter", width: .flexible(1)),
                ReportTable.Column("SK", width: .fixed(36)),
                ReportTable.Column("Verbleib", width: .flexible(2.2)),
            ],
            rows: rows
        )))
        return blocks
    }
}
