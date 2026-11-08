import Foundation
import ELRDDomain

/// Baut aus Vorlage und Einsatzdaten den Bericht (Bausteine bzw. PDF).
public enum ReportBuilder {
    /// Bausteine aller eingeschalteten Kapitel in ihrer Reihenfolge.
    public static func blocks(for template: ReportTemplate, input: ReportInput) -> [ReportBlock] {
        var blocks: [ReportBlock] = []
        for chapter in template.enabledChapters {
            let chapterBlocks: [ReportBlock]
            switch chapter.kind {
            case .missionInfo: chapterBlocks = MissionInfoChapter.blocks(input, options: chapter.options, theme: template.theme)
            case .organisation: chapterBlocks = OrganisationChapter.blocks(input, options: chapter.options)
            case .patients: chapterBlocks = PatientsChapter.blocks(input, options: chapter.options, theme: template.theme)
            case .journal: chapterBlocks = JournalChapter.blocks(input, options: chapter.options)
            case .log: chapterBlocks = LogChapter.blocks(input, options: chapter.options)
            }
            guard !chapterBlocks.isEmpty else { continue }
            if !blocks.isEmpty { blocks.append(.spacer(10)) }
            blocks.append(contentsOf: chapterBlocks)
        }
        if blocks.isEmpty {
            blocks.append(.paragraph("Keine Kapitel ausgewählt.", style: .muted))
        }
        return blocks
    }

    /// Kopf- und Fußzeile: „Einsatzbericht“ · „2026/12 · VU B 19“ · „Erstellt … von …“.
    public static func pageInfo(for template: ReportTemplate, input: ReportInput) -> ReportPageInfo {
        let mission = input.mission
        let created = "Erstellt \(ReportFormat.dateTime(input.createdAt))" + (input.createdBy.isEmpty ? "" : " von \(input.createdBy)")
        return ReportPageInfo(
            title: mission.isExerciseMission ? "ÜBUNG – \(template.name)" : template.name,
            subtitle: "Einsatz \(mission.displayNumber()) · \(mission.title)",
            footer: created + " · ELRD",
            author: input.createdBy
        )
    }

    /// Fertiges PDF. Ohne Hauptthread lauffähig (für die Vorschau im Hintergrund).
    public static func pdf(for template: ReportTemplate, input: ReportInput) -> Data {
        PDFReportRenderer.render(blocks(for: template, input: input), theme: template.theme, info: pageInfo(for: template, input: input))
    }
}
