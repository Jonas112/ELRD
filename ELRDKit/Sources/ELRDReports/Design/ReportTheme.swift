import Foundation
import UIKit
import ELRDDomain

/// Gestaltung eines Berichts (Schritt 39): Akzentfarbe, Schriftgrößen, Format,
/// Logo und Bannertext. Ruhig und gut lesbar, auch schwarzweiß gedruckt.
public struct ReportTheme: Codable, Hashable, Sendable {
    public enum Orientation: String, Codable, Sendable, CaseIterable {
        case portrait, landscape

        public var displayName: String {
            switch self {
            case .portrait: "Hochformat"
            case .landscape: "Querformat"
            }
        }
    }

    /// Akzentfarbe für Überschriften, Tabellenköpfe und Kopfzeile (Standard: ELRD-Blau).
    public var accent: RGBColor
    /// Grundschriftgröße des Fließtexts in Punkt (8–14).
    public var baseFontSize: Double
    public var orientation: Orientation
    /// Logo oben links in der Kopfzeile der ersten Seite (PNG/JPEG).
    public var logo: Data?
    /// Zweite Zeile im Kopf, z. B. „BRK Kreisverband Schweinfurt“.
    public var bannerText: String
    /// SK-Farbmarker in Tabellen (aus: nur Text, z. B. für Schwarzweißdruck).
    public var showsTriageColors: Bool
    /// Wechselnde Zeilenfarbe in Tabellen.
    public var zebraRows: Bool

    public init(
        accent: RGBColor = RGBColor(hex: 0x1F5FAD),
        baseFontSize: Double = 10,
        orientation: Orientation = .portrait,
        logo: Data? = nil,
        bannerText: String = "",
        showsTriageColors: Bool = true,
        zebraRows: Bool = true
    ) {
        self.accent = accent
        self.baseFontSize = min(max(baseFontSize, 8), 14)
        self.orientation = orientation
        self.logo = logo
        self.bannerText = bannerText
        self.showsTriageColors = showsTriageColors
        self.zebraRows = zebraRows
    }

    public static let standard = ReportTheme()

    /// DIN A4 in Punkt.
    public var pageSetup: PageSetup {
        orientation == .portrait ? .a4Portrait : .a4Landscape
    }
}

/// Aufgelöste Schriften und Farben für die Engine.
struct ReportStyle {
    let theme: ReportTheme
    let accent: UIColor
    let text = UIColor(white: 0.10, alpha: 1)
    let muted = UIColor(white: 0.42, alpha: 1)
    let rule = UIColor(white: 0.82, alpha: 1)
    let zebra = UIColor(white: 0.955, alpha: 1)
    let tableHeaderText = UIColor.white

    init(theme: ReportTheme) {
        self.theme = theme
        accent = UIColor(theme.accent)
    }

    var base: CGFloat { CGFloat(theme.baseFontSize) }

    func font(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }

    func headingFont(level: Int) -> UIFont {
        level <= 1 ? font(size: base * 1.6, weight: .bold) : font(size: base * 1.2, weight: .semibold)
    }

    func attributed(_ string: String, style: ReportTextStyle) -> NSAttributedString {
        switch style {
        case .body: attributed(string, font: font(size: base), color: text)
        case .small: attributed(string, font: font(size: base * 0.85), color: text)
        case .muted: attributed(string, font: font(size: base * 0.85), color: muted)
        case .emphasis: attributed(string, font: font(size: base, weight: .semibold), color: text)
        }
    }

    func attributed(_ string: String, font: UIFont, color: UIColor, alignment: NSTextAlignment = .natural, lineSpacing: CGFloat = 1.5) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}

extension UIColor {
    convenience init(_ rgb: RGBColor) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
