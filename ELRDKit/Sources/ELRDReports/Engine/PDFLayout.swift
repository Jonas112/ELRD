import Foundation
import UIKit
import CoreText

/// Seitenformat in Punkt (1/72 Zoll).
public struct PageSetup: Sendable, Equatable {
    public var size: CGSize
    public var marginTop: CGFloat
    public var marginBottom: CGFloat
    public var marginLeft: CGFloat
    public var marginRight: CGFloat
    /// Platz für die Kopfzeile oberhalb des Inhalts.
    public var headerHeight: CGFloat
    /// Platz für die Fußzeile unterhalb des Inhalts.
    public var footerHeight: CGFloat

    public static let a4Portrait = PageSetup(size: CGSize(width: 595.28, height: 841.89))
    public static let a4Landscape = PageSetup(size: CGSize(width: 841.89, height: 595.28))

    public init(
        size: CGSize,
        marginTop: CGFloat = 36,
        marginBottom: CGFloat = 30,
        marginLeft: CGFloat = 46,
        marginRight: CGFloat = 46,
        headerHeight: CGFloat = 44,
        footerHeight: CGFloat = 26
    ) {
        self.size = size
        self.marginTop = marginTop
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
    }

    /// Fläche für den Inhalt (ohne Ränder, Kopf- und Fußzeile).
    public var contentRect: CGRect {
        CGRect(
            x: marginLeft,
            y: marginTop + headerHeight,
            width: size.width - marginLeft - marginRight,
            height: size.height - marginTop - marginBottom - headerHeight - footerHeight
        )
    }
}

/// Eine Zeichenanweisung auf einer Seite.
enum DrawOperation {
    case text(NSAttributedString, CGRect)
    case fill(CGRect, UIColor, cornerRadius: CGFloat)
    case line(from: CGPoint, to: CGPoint, color: UIColor, width: CGFloat)
    case image(CGImage, CGRect)
}

/// Text messen und auf Seitenhöhe zerteilen (Core Text, wie beim Zeichnen).
enum TextMeasure {
    /// Höhe des ganzen Textes bei gegebener Breite.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        return ceil(size.height) + 1
    }

    /// Breite einer Zeile (für Legenden).
    static func width(of text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(text)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// Wie viele Zeichen ab `start` in die Höhe passen (ganze Zeilen) und wie hoch sie sind.
    static func fit(_ text: NSAttributedString, from start: Int, width: CGFloat, height: CGFloat) -> (length: Int, height: CGFloat) {
        guard start < text.length, height > 0 else { return (0, 0) }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var fitRange = CFRange(location: 0, length: 0)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: start, length: 0), nil,
            CGSize(width: width, height: height), &fitRange
        )
        return (fitRange.length, ceil(size.height) + 1)
    }
}

/// Verteilt Bausteine auf Seiten. Ergebnis: Zeichenanweisungen je Seite (ohne
/// Kopf- und Fußzeile, die kennt erst der Renderer mit der Seitenzahl).
struct PDFLayoutEngine {
    let setup: PageSetup
    let style: ReportStyle

    private(set) var pages: [[DrawOperation]] = [[]]
    private var cursorY: CGFloat
    private var content: CGRect { setup.contentRect }

    /// Abstände.
    private let blockSpacing: CGFloat = 8
    private let cellPadding = UIEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)

    init(setup: PageSetup, style: ReportStyle) {
        self.setup = setup
        self.style = style
        cursorY = setup.contentRect.minY
    }

    private var remaining: CGFloat { content.maxY - cursorY }
    private var isAtPageTop: Bool { cursorY <= content.minY + 0.5 }

    mutating func layout(_ blocks: [ReportBlock]) {
        for (index, block) in blocks.enumerated() {
            let next = index + 1 < blocks.count ? blocks[index + 1] : nil
            place(block, followedBy: next)
        }
    }

    private mutating func newPage() {
        pages.append([])
        cursorY = content.minY
    }

    private mutating func add(_ operation: DrawOperation) {
        pages[pages.count - 1].append(operation)
    }

    private mutating func ensure(_ height: CGFloat) {
        if height > remaining, !isAtPageTop { newPage() }
    }

    // MARK: Bausteine

    private mutating func place(_ block: ReportBlock, followedBy next: ReportBlock?) {
        switch block {
        case let .heading(title, level):
            let text = style.attributed(title, font: style.headingFont(level: level), color: level <= 1 ? style.accent : style.text)
            let height = TextMeasure.height(of: text, width: content.width)
            let gapBefore: CGFloat = isAtPageTop ? 0 : (level <= 1 ? 14 : 8)
            // Überschrift nie allein am Seitenende: Platz für sie und etwas Folgendes.
            let keepWithNext = next.map { minimumHeight(of: $0) } ?? 0
            ensure(gapBefore + height + keepWithNext)
            cursorY += isAtPageTop ? 0 : gapBefore
            add(.text(text, CGRect(x: content.minX, y: cursorY, width: content.width, height: height)))
            cursorY += height
            if level <= 1 {
                add(.line(from: CGPoint(x: content.minX, y: cursorY + 1), to: CGPoint(x: content.maxX, y: cursorY + 1), color: style.accent, width: 1.2))
                cursorY += 6
            } else {
                cursorY += 3
            }

        case let .paragraph(string, textStyle):
            placeText(style.attributed(string, style: textStyle))
            cursorY += blockSpacing

        case let .keyValues(pairs):
            placeKeyValues(pairs)
            cursorY += blockSpacing

        case let .table(table):
            placeTable(table)
            cursorY += blockSpacing

        case let .image(image, caption, maxHeight):
            placeImage(image, caption: caption, maxHeight: maxHeight)
            cursorY += blockSpacing

        case let .metrics(metrics):
            placeMetrics(metrics)
            cursorY += blockSpacing

        case let .chart(chart):
            placeChart(chart)
            cursorY += blockSpacing

        case let .spacer(height):
            if !isAtPageTop { cursorY = min(cursorY + height, content.maxY) }

        case .rule:
            ensure(8)
            add(.line(from: CGPoint(x: content.minX, y: cursorY + 3), to: CGPoint(x: content.maxX, y: cursorY + 3), color: style.rule, width: 0.5))
            cursorY += 8

        case .pageBreak:
            if !isAtPageTop { newPage() }
        }
    }

    /// Mindesthöhe, die nach einer Überschrift noch auf die Seite passen muss.
    private func minimumHeight(of block: ReportBlock) -> CGFloat {
        let line = style.base * 1.5
        switch block {
        case .paragraph: return line * 3
        case .keyValues, .table: return line * 3 + 8
        case .image(_, _, let maxHeight): return min(maxHeight, 120)
        case .metrics: return 54
        case .chart(let chart): return chart.height + 30
        default: return line
        }
    }

    /// Fließtext, über Seiten umbrochen (ganze Zeilen).
    private mutating func placeText(_ text: NSAttributedString) {
        var start = 0
        while start < text.length {
            let piece = TextMeasure.fit(text, from: start, width: content.width, height: remaining)
            if piece.length == 0 {
                if isAtPageTop { return } // Zeile höher als die Seite – sollte nicht vorkommen.
                newPage()
                continue
            }
            let range = NSRange(location: start, length: piece.length)
            add(.text(text.attributedSubstring(from: range), CGRect(x: content.minX, y: cursorY, width: content.width, height: piece.height)))
            cursorY += piece.height
            start += piece.length
            if start < text.length { newPage() }
        }
    }

    private mutating func placeKeyValues(_ pairs: [ReportKeyValue]) {
        let keyWidth = min(content.width * 0.32, 170)
        let valueWidth = content.width - keyWidth - 8
        for pair in pairs {
            let key = style.attributed(pair.key, font: style.font(size: style.base * 0.9, weight: .semibold), color: style.muted)
            let value = style.attributed(pair.value.isEmpty ? "–" : pair.value, style: .body)
            let height = max(TextMeasure.height(of: key, width: keyWidth), TextMeasure.height(of: value, width: valueWidth)) + 3
            ensure(height)
            add(.text(key, CGRect(x: content.minX, y: cursorY + 1, width: keyWidth, height: height)))
            add(.text(value, CGRect(x: content.minX + keyWidth + 8, y: cursorY, width: valueWidth, height: height)))
            cursorY += height
        }
    }

    private mutating func placeTable(_ table: ReportTable) {
        guard !table.columns.isEmpty else { return }
        let widths = table.columnWidths(for: content.width)
        let headerCells = table.columns.map { ReportTable.Cell($0.title, isBold: true) }
        let headerHeight = rowHeight(headerCells, widths: widths, isHeader: true)
        // Kopf plus erste Zeile zusammenhalten.
        let firstRow = table.rows.first.map { rowHeight($0, widths: widths, isHeader: false) } ?? 0
        ensure(headerHeight + firstRow)
        drawRow(headerCells, widths: widths, height: headerHeight, columns: table.columns, isHeader: true, index: 0)
        for (index, row) in table.rows.enumerated() {
            let height = rowHeight(row, widths: widths, isHeader: false)
            if height > remaining, !isAtPageTop {
                newPage()
                drawRow(headerCells, widths: widths, height: headerHeight, columns: table.columns, isHeader: true, index: 0)
            }
            drawRow(row, widths: widths, height: height, columns: table.columns, isHeader: false, index: index)
        }
        add(.line(from: CGPoint(x: content.minX, y: cursorY), to: CGPoint(x: content.maxX, y: cursorY), color: style.rule, width: 0.5))
    }

    private func cellText(_ cell: ReportTable.Cell, isHeader: Bool, alignsRight: Bool) -> NSAttributedString {
        let size = style.base * (isHeader ? 0.85 : 0.9)
        let color: UIColor = isHeader ? style.tableHeaderText : cell.textColor.map { UIColor($0) } ?? style.text
        return style.attributed(
            cell.text,
            font: style.font(size: size, weight: isHeader || cell.isBold ? .semibold : .regular),
            color: color,
            alignment: alignsRight ? .right : .natural,
            lineSpacing: 0.5
        )
    }

    private func rowHeight(_ cells: [ReportTable.Cell], widths: [CGFloat], isHeader: Bool) -> CGFloat {
        let heights = zip(cells, widths).map { cell, width in
            TextMeasure.height(of: cellText(cell, isHeader: isHeader, alignsRight: false), width: max(width - cellPadding.left - cellPadding.right, 1))
        }
        return (heights.max() ?? 0) + cellPadding.top + cellPadding.bottom
    }

    private mutating func drawRow(_ cells: [ReportTable.Cell], widths: [CGFloat], height: CGFloat, columns: [ReportTable.Column], isHeader: Bool, index: Int) {
        let rowRect = CGRect(x: content.minX, y: cursorY, width: content.width, height: height)
        if isHeader {
            add(.fill(rowRect, style.accent, cornerRadius: 0))
        } else if style.theme.zebraRows, index % 2 == 1 {
            add(.fill(rowRect, style.zebra, cornerRadius: 0))
        }
        var x = content.minX
        for (column, (cell, width)) in zip(columns, zip(cells, widths)) {
            let cellRect = CGRect(x: x, y: cursorY, width: width, height: height)
            if !isHeader, let fill = cell.fill {
                add(.fill(cellRect.insetBy(dx: 1, dy: 1), UIColor(fill), cornerRadius: 2))
            }
            let text = cellText(cell, isHeader: isHeader, alignsRight: column.alignsRight)
            add(.text(text, CGRect(
                x: x + cellPadding.left,
                y: cursorY + cellPadding.top,
                width: max(width - cellPadding.left - cellPadding.right, 1),
                height: height - cellPadding.top - cellPadding.bottom
            )))
            x += width
        }
        if !isHeader {
            add(.line(from: CGPoint(x: content.minX, y: cursorY + height), to: CGPoint(x: content.maxX, y: cursorY + height), color: style.rule, width: 0.3))
        }
        cursorY += height
    }

    private mutating func placeImage(_ image: CGImage, caption: String?, maxHeight: CGFloat) {
        guard image.width > 0, image.height > 0 else { return }
        let ratio = CGFloat(image.height) / CGFloat(image.width)
        var width = content.width
        var height = width * ratio
        let limit = min(maxHeight, content.height - 30)
        if height > limit {
            height = limit
            width = height / ratio
        }
        let captionText = caption.map { style.attributed($0, style: .muted) }
        let captionHeight = captionText.map { TextMeasure.height(of: $0, width: content.width) + 2 } ?? 0
        ensure(height + captionHeight)
        add(.image(image, CGRect(x: content.minX, y: cursorY, width: width, height: height)))
        cursorY += height + 2
        if let captionText {
            add(.text(captionText, CGRect(x: content.minX, y: cursorY, width: content.width, height: captionHeight)))
            cursorY += captionHeight
        }
    }

    private mutating func placeMetrics(_ metrics: [ReportMetric]) {
        guard !metrics.isEmpty else { return }
        let spacing: CGFloat = 6
        let width = (content.width - spacing * CGFloat(metrics.count - 1)) / CGFloat(metrics.count)
        let height: CGFloat = style.base * 4.4
        ensure(height)
        for (index, metric) in metrics.enumerated() {
            let x = content.minX + CGFloat(index) * (width + spacing)
            let rect = CGRect(x: x, y: cursorY, width: width, height: height)
            add(.fill(rect, metric.fill.map { UIColor($0) } ?? style.zebra, cornerRadius: 4))
            let color = metric.textColor.map { UIColor($0) } ?? style.text
            let value = style.attributed(metric.value, font: style.font(size: style.base * 1.8, weight: .bold), color: color, alignment: .center, lineSpacing: 0)
            let label = style.attributed(metric.label, font: style.font(size: style.base * 0.75, weight: .medium), color: color, alignment: .center, lineSpacing: 0)
            add(.text(value, CGRect(x: x + 2, y: cursorY + 5, width: width - 4, height: style.base * 2.4)))
            add(.text(label, CGRect(x: x + 2, y: cursorY + style.base * 2.7, width: width - 4, height: style.base * 1.6)))
        }
        cursorY += height
    }

    /// Stufen-Liniendiagramm mit Achsen, Rasterlinien und Legende (Schritt 137).
    private mutating func placeChart(_ chart: ReportChart) {
        let titleText = style.attributed(chart.title, style: .emphasis)
        let titleHeight = TextMeasure.height(of: titleText, width: content.width)
        let legendHeight = style.base * 1.6
        let axisHeight = style.base * 1.4
        ensure(titleHeight + 4 + chart.height + axisHeight + legendHeight)
        add(.text(titleText, CGRect(x: content.minX, y: cursorY, width: content.width, height: titleHeight)))
        cursorY += titleHeight + 4

        let labelWidth: CGFloat = 24
        let plot = CGRect(x: content.minX + labelWidth, y: cursorY, width: content.width - labelWidth, height: chart.height)
        let maxValue = chart.maxValue
        let span = chart.end.timeIntervalSince(chart.start)
        func x(_ date: Date) -> CGFloat { plot.minX + plot.width * CGFloat(min(max(date.timeIntervalSince(chart.start) / span, 0), 1)) }
        func y(_ value: Int) -> CGFloat { plot.maxY - plot.height * CGFloat(value) / CGFloat(maxValue) }

        // Rasterlinien mit Werten (höchstens 5).
        let step = max(1, Int((Double(maxValue) / 4).rounded(.up)))
        for value in stride(from: 0, through: maxValue, by: step) {
            add(.line(from: CGPoint(x: plot.minX, y: y(value)), to: CGPoint(x: plot.maxX, y: y(value)), color: style.rule, width: value == 0 ? 0.8 : 0.3))
            let label = style.attributed("\(value)", font: style.font(size: style.base * 0.75), color: style.muted, alignment: .right, lineSpacing: 0)
            add(.text(label, CGRect(x: content.minX, y: y(value) - style.base * 0.55, width: labelWidth - 4, height: style.base)))
        }
        // Reihen als Stufenlinie.
        for series in chart.series {
            let color = UIColor(series.color)
            var points = series.points.sorted { $0.date < $1.date }
            if let last = points.last, last.date < chart.end { points.append((chart.end, last.value)) }
            for index in points.indices.dropLast() {
                let current = points[index], next = points[index + 1]
                add(.line(from: CGPoint(x: x(current.date), y: y(current.value)), to: CGPoint(x: x(next.date), y: y(current.value)), color: color, width: 2.2))
                if next.value != current.value {
                    add(.line(from: CGPoint(x: x(next.date), y: y(current.value)), to: CGPoint(x: x(next.date), y: y(next.value)), color: color, width: 2.2))
                }
            }
        }
        cursorY += chart.height + 2
        // Zeitachse: Beginn, Mitte, Ende.
        let times = [chart.start, chart.start.addingTimeInterval(span / 2), chart.end]
        for (index, date) in times.enumerated() {
            let alignment: NSTextAlignment = index == 0 ? .left : index == 1 ? .center : .right
            let text = style.attributed(ReportFormat.time(date), font: style.font(size: style.base * 0.75), color: style.muted, alignment: alignment, lineSpacing: 0)
            add(.text(text, CGRect(x: plot.minX, y: cursorY, width: plot.width, height: axisHeight)))
        }
        cursorY += axisHeight
        // Legende.
        var legendX = plot.minX
        for series in chart.series {
            add(.fill(CGRect(x: legendX, y: cursorY + style.base * 0.35, width: 12, height: 4), UIColor(series.color), cornerRadius: 1))
            let text = style.attributed(series.label, font: style.font(size: style.base * 0.8, weight: .medium), color: style.text, lineSpacing: 0)
            let width = TextMeasure.width(of: text) + 4
            add(.text(text, CGRect(x: legendX + 16, y: cursorY, width: width, height: legendHeight)))
            legendX += 16 + width + 12
        }
        cursorY += legendHeight
    }
}
