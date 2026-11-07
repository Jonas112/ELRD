import Foundation
import UIKit
import ELRDDomain

/// Kapitel „Tagebuch“ (Schritt 43): Einträge in zeitlicher Folge mit Uhrzeit,
/// Nummer, Verfasser und Bildern; Sprachnotizen als Hinweis mit Dauer.
enum JournalChapter {
    static func blocks(_ input: ReportInput, options: ReportChapterOptions) -> [ReportBlock] {
        let entries = JournalEntry.chronological(input.journal)
        var blocks: [ReportBlock] = [.heading(ReportChapter.Kind.journal.displayName, level: 1)]
        guard !entries.isEmpty else {
            blocks.append(.paragraph("Keine Einträge.", style: .muted))
            return blocks
        }
        for entry in entries {
            let author = entry.metadata.createdBy.flatMap { input.people[$0] }
            var key = "\(ReportFormat.time(entry.occurredAt)) · \(entry.number)"
            if let author { key += "\n\(author)" }
            var text = entry.text
            if entry.origin != .manual { text = "[\(entry.origin.displayName)] " + text }
            let audio = entry.attachments.filter { $0.kind == .audio }
            if !audio.isEmpty {
                let durations = audio.map { "Sprachnotiz " + minutes($0.duration ?? 0) }
                text += (text.isEmpty ? "" : "\n") + durations.joined(separator: ", ")
            }
            blocks.append(.keyValues([ReportKeyValue(key, text.isEmpty ? "–" : text)]))
            guard options.journalImageHeight > 0 else { continue }
            let images = entry.attachments.filter { $0.kind == .photo || $0.kind == .drawing }
            for (index, file) in images.enumerated() {
                guard let data = input.imageData(file), let image = UIImage(data: data)?.cgImage else {
                    blocks.append(.paragraph("(Bild nicht auf diesem Gerät)", style: .muted))
                    continue
                }
                let caption = images.count > 1 ? "\(entry.number), Bild \(index + 1) von \(images.count)" : nil
                blocks.append(.image(image, caption: caption, maxHeight: CGFloat(options.journalImageHeight)))
            }
            blocks.append(.rule)
        }
        return blocks
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Kapitel „Protokoll“ (Schritt 43): jede Aktion mit Uhrzeit, Bereich und Person.
enum LogChapter {
    static func blocks(_ input: ReportInput, options: ReportChapterOptions) -> [ReportBlock] {
        let entries = input.log
            .filter { options.logCategories.isEmpty || options.logCategories.contains($0.category) }
            .sorted { $0.timestamp < $1.timestamp }
        var blocks: [ReportBlock] = [.heading(ReportChapter.Kind.log.displayName, level: 1)]
        if !options.logCategories.isEmpty {
            let names = LogCategory.allCases.filter { options.logCategories.contains($0) }.map(\.displayName)
            blocks.append(.paragraph("Bereiche: \(names.joined(separator: ", "))", style: .muted))
        }
        guard !entries.isEmpty else {
            blocks.append(.paragraph("Keine Einträge.", style: .muted))
            return blocks
        }
        let table = ReportTable(
            columns: [
                ReportTable.Column("Zeit", width: .fixed(56)),
                ReportTable.Column("Bereich", width: .fixed(78)),
                ReportTable.Column("Aktion", width: .flexible(3)),
                ReportTable.Column("Person", width: .flexible(1)),
            ],
            rows: entries.map { entry in
                [
                    ReportTable.Cell(seconds(entry.timestamp)),
                    ReportTable.Cell(entry.category.displayName),
                    ReportTable.Cell(entry.message),
                    ReportTable.Cell(entry.authorID.flatMap { input.people[$0] } ?? "–"),
                ]
            }
        )
        blocks.append(.table(table))
        return blocks
    }

    static func seconds(_ date: Date) -> String {
        date.formatted(.dateTime.locale(ReportFormat.locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
