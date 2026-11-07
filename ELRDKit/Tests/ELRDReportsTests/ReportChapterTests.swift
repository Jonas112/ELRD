import Foundation
import Testing
import PDFKit
@testable import ELRDReports
@testable import ELRDDomain
import ELRDStore

@Suite("Kapitel Patienten, Tagebuch, Protokoll")
@MainActor
struct ReportChapterTests {
    func input(_ store: MissionStore) -> ReportInput {
        let state = store.state
        return ReportInput(mission: state.mission, patients: state.patients, units: state.units, sections: state.sections,
                           journal: state.journal, log: state.visibleLog, createdBy: "Erika Muster")
    }

    func tables(_ blocks: [ReportBlock]) -> [ReportTable] {
        blocks.compactMap { block in
            if case let .table(table) = block { return table }
            return nil
        }
    }

    @Test func patientTableFiltersAndHidesNames() throws {
        let store = try PreviewData.makeStore() // 7 Patienten
        let report = input(store)
        var options = ReportChapterOptions()
        let all = tables(PatientsChapter.blocks(report, options: options, theme: .standard))
        #expect(all.first?.rows.count == store.state.activePatients.count)
        #expect(all.first?.columns.map(\.title).contains("Name") == true)

        options.showsPatientNames = false
        options.triageFilter = [.sk1]
        let sk1 = tables(PatientsChapter.blocks(report, options: options, theme: .standard))
        let expected = store.state.activePatients.filter { $0.triage == .sk1 }.count
        #expect(sk1.first?.rows.count ?? 0 == expected)
        #expect(sk1.first?.columns.map(\.title).contains("Name") == false, "Datenschutz: ohne Namen")
    }

    @Test func patientSheetsStartOnNewPages() throws {
        let store = try PreviewData.makeStore()
        var options = ReportChapterOptions()
        options.usesPatientSheets = true
        let blocks = PatientsChapter.blocks(input(store), options: options, theme: .standard)
        let breaks = blocks.filter { if case .pageBreak = $0 { return true } else { return false } }.count
        #expect(breaks == store.state.activePatients.count - 1)
        var template = ReportTemplate.full
        template.chapters = [ReportChapter(kind: .patients, options: options)]
        let pdf = try #require(PDFDocument(data: ReportBuilder.pdf(for: template, input: input(store))))
        #expect(pdf.pageCount >= store.state.activePatients.count)
    }

    @Test func journalAndLogAreChronological() throws {
        let store = try PreviewData.makeStore()
        try store.perform(AddJournalText("Erstmeldung an ILS abgegeben"))
        let report = input(store)
        let journal = JournalChapter.blocks(report, options: ReportChapterOptions())
        let journalTexts = journal.compactMap { block -> String? in
            if case let .keyValues(pairs) = block { return pairs.first?.value }
            return nil
        }
        #expect(journalTexts.last == "Erstmeldung an ILS abgegeben")

        let log = tables(LogChapter.blocks(report, options: ReportChapterOptions()))
        #expect(log.first?.rows.count == report.log.count)
        var options = ReportChapterOptions()
        options.logCategories = [.journal]
        let filtered = tables(LogChapter.blocks(report, options: options))
        #expect(filtered.first?.rows.allSatisfy { $0[1].text == LogCategory.journal.displayName } == true)

        let pdf = try #require(PDFDocument(data: ReportBuilder.pdf(for: .full, input: report)))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        #expect(text.contains("Patienten"))
        #expect(text.contains("Tagebuch"))
        #expect(text.contains("Protokoll"))
        #expect(text.contains("Erstmeldung"))
    }
}
