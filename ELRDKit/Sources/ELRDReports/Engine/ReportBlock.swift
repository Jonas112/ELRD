import CoreGraphics
import ELRDDomain

/// Baustein eines Berichts. Kapitel liefern Bausteine, die Engine verteilt sie auf
/// Seiten (Umbrüche, wiederholte Tabellenköpfe) und das Theme bestimmt das Aussehen.
public enum ReportBlock {
    /// Überschrift; Stufe 1 = Kapitel, 2 = Abschnitt. Bleibt mit dem Folgenden zusammen.
    case heading(String, level: Int)
    /// Fließtext; wird bei Bedarf über Seiten umbrochen.
    case paragraph(String, style: ReportTextStyle = .body)
    /// Bezeichnung–Wert-Paare in zwei Spalten (z. B. Einsatzdaten).
    case keyValues([ReportKeyValue])
    /// Tabelle mit Kopfzeile, die auf jeder Folgeseite wiederholt wird.
    case table(ReportTable)
    /// Bild in Satzbreite (höchstens `maxHeight`), optional mit Unterschrift.
    case image(CGImage, caption: String?, maxHeight: CGFloat)
    /// Kennzahlen als Kacheln in einer Reihe (z. B. Sichtung).
    case metrics([ReportMetric])
    case spacer(CGFloat)
    /// Feine Trennlinie.
    case rule
    case pageBreak
}

public enum ReportTextStyle: Sendable, Equatable {
    case body
    case small
    case muted
    case emphasis
}

public struct ReportKeyValue: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// Kennzahl-Kachel: großer Wert, kleine Bezeichnung, optional Farbe (SK).
public struct ReportMetric: Sendable, Equatable {
    public let value: String
    public let label: String
    public let fill: RGBColor?
    public let textColor: RGBColor?

    public init(value: String, label: String, fill: RGBColor? = nil, textColor: RGBColor? = nil) {
        self.value = value
        self.label = label
        self.fill = fill
        self.textColor = textColor
    }
}

public struct ReportTable: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public enum Width: Sendable, Equatable {
            /// Feste Breite in Punkt.
            case fixed(CGFloat)
            /// Anteil am restlichen Platz.
            case flexible(CGFloat)
        }

        public let title: String
        public let width: Width
        public let alignsRight: Bool

        public init(_ title: String, width: Width = .flexible(1), alignsRight: Bool = false) {
            self.title = title
            self.width = width
            self.alignsRight = alignsRight
        }
    }

    public struct Cell: Sendable, Equatable {
        public let text: String
        /// Hintergrund der Zelle (z. B. SK-Farbe).
        public let fill: RGBColor?
        public let textColor: RGBColor?
        public let isBold: Bool

        public init(_ text: String, fill: RGBColor? = nil, textColor: RGBColor? = nil, isBold: Bool = false) {
            self.text = text
            self.fill = fill
            self.textColor = textColor
            self.isBold = isBold
        }
    }

    public let columns: [Column]
    public let rows: [[Cell]]

    public init(columns: [Column], rows: [[Cell]]) {
        self.columns = columns
        // Fehlende Zellen auffüllen, überzählige abschneiden.
        self.rows = rows.map { row in
            Array((row + Array(repeating: Cell(""), count: max(0, columns.count - row.count))).prefix(columns.count))
        }
    }

    /// Spaltenbreiten für die verfügbare Breite.
    public func columnWidths(for totalWidth: CGFloat) -> [CGFloat] {
        let fixed = columns.reduce(CGFloat(0)) { sum, column in
            if case .fixed(let value) = column.width { return sum + value }
            return sum
        }
        let weights = columns.reduce(CGFloat(0)) { sum, column in
            if case .flexible(let weight) = column.width { return sum + max(weight, 0) }
            return sum
        }
        let rest = max(totalWidth - fixed, 0)
        return columns.map { column in
            switch column.width {
            case .fixed(let value): return value
            case .flexible(let weight): return weights > 0 ? rest * max(weight, 0) / weights : 0
            }
        }
    }
}
