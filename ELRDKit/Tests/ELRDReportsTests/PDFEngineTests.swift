import Foundation
import Testing
import PDFKit
@testable import ELRDReports
@testable import ELRDDomain

@Suite("PDF-Engine: Seitenfluss, Tabellen, Kopf- und Fußzeile")
struct PDFEngineTests {
    let info = ReportPageInfo(title: "Einsatzbericht", subtitle: "Einsatz 2026/12 · VU B 19", footer: "Erstellt heute")

    func document(_ blocks: [ReportBlock], theme: ReportTheme = .standard) throws -> PDFDocument {
        let data = PDFReportRenderer.render(blocks, theme: theme, info: info)
        return try #require(PDFDocument(data: data))
    }

    @Test func longTextFlowsOverPagesWithPageNumbers() throws {
        let sentence = "Die Einsatzstelle wurde erkundet und die Lage an die Leitstelle gemeldet. "
        let blocks: [ReportBlock] = [
            .heading("Tagebuch", level: 1),
            .paragraph(String(repeating: sentence, count: 400)),
        ]
        let pdf = try document(blocks)
        #expect(pdf.pageCount >= 3)
        #expect(pdf.pageCount == PDFReportRenderer.pageCount(blocks, theme: .standard))
        let first = try #require(pdf.page(at: 0)?.string)
        let last = try #require(pdf.page(at: pdf.pageCount - 1)?.string)
        #expect(first.contains("Seite 1 von \(pdf.pageCount)"))
        #expect(last.contains("Seite \(pdf.pageCount) von \(pdf.pageCount)"))
        #expect(first.contains("Einsatzbericht"), "Kopfzeile")
        #expect(first.contains("Leitstelle"), "echter, durchsuchbarer Text")
        // Kein Text geht verloren: jedes Vorkommen landet auf irgendeiner Seite.
        let all = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: " ")
        let found = all.components(separatedBy: "Leitstelle").count - 1
        #expect(found == 400)
    }

    @Test func tableHeaderRepeatsOnFollowingPages() throws {
        let table = ReportTable(
            columns: [ReportTable.Column("Nr.", width: .fixed(40)), ReportTable.Column("Funkrufname"), ReportTable.Column("Patienten", width: .flexible(2))],
            rows: (1...150).map { [ReportTable.Cell("\($0)"), ReportTable.Cell("RK SWFT 71/\($0)"), ReportTable.Cell("A-\($0) (SK 2)")] }
        )
        let pdf = try document([.heading("Organisation", level: 1), .table(table)])
        #expect(pdf.pageCount >= 3)
        for index in 0..<pdf.pageCount {
            let text = try #require(pdf.page(at: index)?.string)
            #expect(text.contains("Funkrufname"), "Tabellenkopf auf Seite \(index + 1)")
        }
        let all = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        #expect(all.contains("RK SWFT 71/150"), "letzte Zeile vorhanden")
    }

    @Test func headingIsNotLeftAloneAtPageEnd() throws {
        // Seite fast füllen, dann Überschrift + Text: die Überschrift muss auf Seite 2.
        var engine = PDFLayoutEngine(setup: .a4Portrait, style: ReportStyle(theme: .standard))
        engine.layout([.paragraph("Start"), .spacer(PageSetup.a4Portrait.contentRect.height - 60), .heading("Patienten", level: 1), .paragraph("Text")])
        #expect(engine.pages.count == 2)
        let secondPageTexts = engine.pages[1].compactMap { operation -> String? in
            if case let .text(text, _) = operation { return text.string }
            return nil
        }
        #expect(secondPageTexts.first == "Patienten")
    }

    @Test func columnWidthsFillTheLine() {
        let table = ReportTable(columns: [ReportTable.Column("A", width: .fixed(50)), ReportTable.Column("B", width: .flexible(1)), ReportTable.Column("C", width: .flexible(3))], rows: [[ReportTable.Cell("x")]])
        let widths = table.columnWidths(for: 450)
        #expect(widths == [50, 100, 300])
        #expect(table.rows.first?.count == 3, "fehlende Zellen aufgefüllt")
    }

    @Test func landscapeAndThemeAffectPages() throws {
        var theme = ReportTheme.standard
        theme.orientation = .landscape
        theme.bannerText = "BRK Kreisverband Schweinfurt"
        let pdf = try document([.paragraph("Kurz")], theme: theme)
        let bounds = try #require(pdf.page(at: 0)?.bounds(for: .mediaBox))
        #expect(bounds.width > bounds.height, "Querformat")
        #expect(pdf.page(at: 0)?.string?.contains("BRK Kreisverband Schweinfurt") == true)
        #expect(ReportTheme(baseFontSize: 40).baseFontSize == 14, "Schriftgröße begrenzt")
    }
}
