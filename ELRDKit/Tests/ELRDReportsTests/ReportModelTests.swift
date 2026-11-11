import Foundation
import Testing
import PDFKit
@testable import ELRDReports
@testable import ELRDDomain
import ELRDStore

@Suite("Berichtsmodell und erste Kapitel")
@MainActor
struct ReportModelTests {
    func input(_ store: MissionStore) -> ReportInput {
        let state = store.state
        return ReportInput(
            mission: state.mission,
            patients: state.patients,
            units: state.units,
            sections: state.sections,
            journal: state.journal,
            log: state.visibleLog,
            createdAt: Date(),
            createdBy: "Erika Muster"
        )
    }

    @Test func templateRoundTripsAndOldOptionsGetDefaults() throws {
        var template = ReportTemplate.full
        template.chapters[1].isEnabled = false
        template.chapters[0].options.showsMapImage = false
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(ReportTemplate.self, from: data)
        #expect(decoded == template)
        #expect(decoded.enabledChapters.map(\.kind) == [.missionInfo, .patients, .journal, .log])

        let old = try JSONDecoder().decode(ReportChapterOptions.self, from: Data(#"{"showsSummary":false}"#.utf8))
        #expect(old.showsSummary == false)
        #expect(old.includesPlaceholders, "fehlende Option → Standard")
    }

    @Test func missionInfoAndOrganisationChapters() throws {
        let store = try PreviewData.makeStore() // RD 3 im Bereitstellungsraum, 7 Patienten
        let report = input(store)
        let pdfData = ReportBuilder.pdf(for: .full, input: report)
        let pdf = try #require(PDFDocument(data: pdfData))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        #expect(text.contains("Einsatzdaten"))
        #expect(text.contains("Lage in Zahlen"))
        #expect(text.contains("Organisation"))
        #expect(text.contains("Bereitstellungsraum (Initialabschnitt)"))
        #expect(text.contains("unbekannt"), "Platzhalter erscheinen")
        #expect(text.contains("Erika Muster"), "Fußzeile nennt Ersteller")

        var withoutPlaceholders = ReportTemplate.full
        withoutPlaceholders.chapters[1].options.includesPlaceholders = false
        let blocks = ReportBuilder.blocks(for: withoutPlaceholders, input: report)
        let tables = blocks.compactMap { block -> ReportTable? in
            if case let .table(table) = block { return table }
            return nil
        }
        #expect(tables.allSatisfy { table in table.rows.allSatisfy { !$0[1].text.contains("Fahrzeug unbekannt") } })
    }

    @Test func coverWithChartStartsReport() throws {
        let store = try PreviewData.makeStore()
        let report = input(store)
        let blocks = ReportBuilder.blocks(for: .full, input: report)
        guard case .spacer = blocks.first else {
            Issue.record("Deckblatt erwartet")
            return
        }
        let firstBreak = try #require(blocks.firstIndex { if case .pageBreak = $0 { return true } else { return false } })
        let cover = blocks[..<firstBreak]
        #expect(cover.contains { if case .paragraph(_, .title) = $0 { return true } else { return false } })
        let chart = cover.compactMap { block -> ReportChart? in
            if case let .chart(chart) = block { return chart }
            return nil
        }.first
        #expect(chart?.series.isEmpty == false, "SK-Verlauf auf dem Deckblatt")
        let pdf = try #require(PDFDocument(data: ReportBuilder.pdf(for: .full, input: report)))
        #expect(pdf.pageCount >= 2)

        var plain = ReportTemplate.full
        plain.chapters[0].options.showsCover = false
        let withoutCover = ReportBuilder.blocks(for: plain, input: report)
        #expect(!withoutCover.contains { if case .paragraph(_, .title) = $0 { return true } else { return false } })
    }

    @Test func metricsShowTriageAlwaysForSK1to3() {
        let metrics = MissionInfoChapter.triageMetrics([], theme: .standard)
        #expect(metrics.map(\.label) == ["Patienten", "SK 1", "SK 2", "SK 3"])
        var plain = ReportTheme.standard
        plain.showsTriageColors = false
        #expect(MissionInfoChapter.triageMetrics([], theme: plain).allSatisfy { $0.fill == nil })
    }
}
