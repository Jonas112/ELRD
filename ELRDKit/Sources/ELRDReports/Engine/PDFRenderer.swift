import Foundation
import UIKit
import CoreText

/// Kopf- und Fußzeilentexte eines Berichts.
public struct ReportPageInfo: Sendable, Equatable {
    /// Links im Kopf, z. B. „Einsatzbericht“.
    public var title: String
    /// Rechts im Kopf, z. B. „2026/12 · VU B 19“.
    public var subtitle: String
    /// Links im Fuß, z. B. „Erstellt 06.11.2026 07:12 von Erika Muster“.
    public var footer: String
    /// Metadaten der PDF-Datei.
    public var author: String

    public init(title: String, subtitle: String = "", footer: String = "", author: String = "") {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.author = author
    }
}

/// Erzeugt das PDF: Bausteine → Seiten (`PDFLayoutEngine`) → Zeichnen mit Kopf- und
/// Fußzeile „Seite x von y“. Echter, durchsuchbarer Text (Core Text). Läuft ohne
/// Hauptthread, kann also im Hintergrund gerendert werden.
public enum PDFReportRenderer {
    public static func render(_ blocks: [ReportBlock], theme: ReportTheme, info: ReportPageInfo) -> Data {
        let setup = theme.pageSetup
        let style = ReportStyle(theme: theme)
        var engine = PDFLayoutEngine(setup: setup, style: style)
        engine.layout(blocks)
        let pages = engine.pages
        let logo = theme.logo.flatMap { UIImage(data: $0)?.cgImage }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: info.title + (info.subtitle.isEmpty ? "" : " – \(info.subtitle)"),
            kCGPDFContextAuthor as String: info.author,
            kCGPDFContextCreator as String: "ELRD",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: setup.size), format: format)
        return renderer.pdfData { context in
            for (index, operations) in pages.enumerated() {
                context.beginPage()
                let cg = context.cgContext
                drawHeader(in: cg, setup: setup, style: style, info: info, logo: index == 0 ? logo : nil)
                for operation in operations { draw(operation, in: cg) }
                drawFooter(in: cg, setup: setup, style: style, info: info, page: index + 1, of: pages.count)
            }
        }
    }

    /// Anzahl der Seiten, ohne zu zeichnen (z. B. für die Vorschau).
    public static func pageCount(_ blocks: [ReportBlock], theme: ReportTheme) -> Int {
        var engine = PDFLayoutEngine(setup: theme.pageSetup, style: ReportStyle(theme: theme))
        engine.layout(blocks)
        return engine.pages.count
    }

    // MARK: Zeichnen

    static func draw(_ operation: DrawOperation, in context: CGContext) {
        switch operation {
        case let .text(text, rect):
            drawText(text, in: rect, context: context)
        case let .fill(rect, color, radius):
            context.setFillColor(color.cgColor)
            if radius > 0 {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            } else {
                context.fill(rect)
            }
        case let .line(from, to, color, width):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        case let .image(image, rect):
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }

    /// Text oben bündig im Rechteck (Core Text zeichnet im gespiegelten System).
    static func drawText(_ text: NSAttributedString, in rect: CGRect, context: CGContext) {
        guard text.length > 0, rect.width > 0, rect.height > 0 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func drawHeader(in context: CGContext, setup: PageSetup, style: ReportStyle, info: ReportPageInfo, logo: CGImage?) {
        let top = setup.marginTop
        let left = setup.marginLeft
        let width = setup.size.width - setup.marginLeft - setup.marginRight
        var textX = left
        if let logo, logo.width > 0 {
            let height: CGFloat = 30
            let logoWidth = min(height * CGFloat(logo.width) / CGFloat(logo.height), 120)
            draw(.image(logo, CGRect(x: left, y: top, width: logoWidth, height: height)), in: context)
            textX += logoWidth + 10
        }
        let title = style.attributed(info.title, font: style.font(size: style.base * 1.1, weight: .bold), color: style.accent, lineSpacing: 0)
        drawText(title, in: CGRect(x: textX, y: top, width: width * 0.55, height: style.base * 1.6), context: context)
        if !style.theme.bannerText.isEmpty {
            let banner = style.attributed(style.theme.bannerText, font: style.font(size: style.base * 0.8), color: style.muted, lineSpacing: 0)
            drawText(banner, in: CGRect(x: textX, y: top + style.base * 1.6, width: width * 0.55, height: style.base * 1.3), context: context)
        }
        if !info.subtitle.isEmpty {
            let subtitle = style.attributed(info.subtitle, font: style.font(size: style.base * 0.9, weight: .medium), color: style.text, alignment: .right, lineSpacing: 0)
            drawText(subtitle, in: CGRect(x: left + width * 0.45, y: top + 2, width: width * 0.55, height: style.base * 2.8), context: context)
        }
        let lineY = top + setup.headerHeight - 10
        draw(.line(from: CGPoint(x: left, y: lineY), to: CGPoint(x: left + width, y: lineY), color: style.rule, width: 0.6), in: context)
    }

    private static func drawFooter(in context: CGContext, setup: PageSetup, style: ReportStyle, info: ReportPageInfo, page: Int, of total: Int) {
        let left = setup.marginLeft
        let width = setup.size.width - setup.marginLeft - setup.marginRight
        let y = setup.size.height - setup.marginBottom - setup.footerHeight + 8
        draw(.line(from: CGPoint(x: left, y: y - 4), to: CGPoint(x: left + width, y: y - 4), color: style.rule, width: 0.6), in: context)
        let font = style.font(size: style.base * 0.75)
        if !info.footer.isEmpty {
            drawText(style.attributed(info.footer, font: font, color: style.muted, lineSpacing: 0),
                     in: CGRect(x: left, y: y, width: width * 0.7, height: style.base * 1.4), context: context)
        }
        drawText(style.attributed("Seite \(page) von \(total)", font: font, color: style.muted, alignment: .right, lineSpacing: 0),
                 in: CGRect(x: left + width * 0.7, y: y, width: width * 0.3, height: style.base * 1.4), context: context)
    }
}
