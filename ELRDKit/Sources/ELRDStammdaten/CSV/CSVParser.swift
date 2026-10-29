import Foundation

/// Liest CSV-Dateien, wie sie aus Excel, Numbers oder Leitstellensystemen kommen.
///
/// - Trennzeichen „;“ oder „,“ (automatisch erkannt an der ersten Zeile)
/// - Felder in Anführungszeichen, auch mit Trennzeichen und Zeilenumbrüchen darin
/// - UTF-8 mit oder ohne BOM; Windows-, Unix- und alte Mac-Zeilenenden
/// - Leere Zeilen werden übersprungen
public struct CSVParser: Sendable {
    public struct Row: Hashable, Sendable {
        /// Zeilennummer in der Datei (ab 1), für Fehlermeldungen.
        public let line: Int
        public let fields: [String]

        public subscript(index: Int) -> String? {
            fields.indices.contains(index) ? fields[index] : nil
        }
    }

    public let delimiter: Character

    public init(delimiter: Character) {
        self.delimiter = delimiter
    }

    /// Erkennt das Trennzeichen anhand der ersten Zeile.
    public static func detectDelimiter(in text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first ?? ""
        let semicolons = firstLine.filter { $0 == ";" }.count
        let commas = firstLine.filter { $0 == "," }.count
        return commas > semicolons ? "," : ";"
    }

    public static func parse(_ text: String) -> [Row] {
        CSVParser(delimiter: detectDelimiter(in: text)).parse(text)
    }

    public static func parse(data: Data) throws -> [Row] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CSVError.unreadableEncoding
        }
        return parse(text)
    }

    public func parse(_ input: String) -> [Row] {
        let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
        var rows: [Row] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var rowStartLine = 1
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil

        func finishRow() {
            fields.append(field)
            field = ""
            let trimmed = fields.map { $0.trimmingCharacters(in: .whitespaces) }
            if trimmed.contains(where: { !$0.isEmpty }) {
                // Leere Felder am Zeilenende (z. B. „R AB 71/1;RTW;“) entfernen.
                var cleaned = trimmed
                while cleaned.last?.isEmpty == true { cleaned.removeLast() }
                rows.append(Row(line: rowStartLine, fields: cleaned))
            }
            fields = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    if character.isNewline { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.trimmingCharacters(in: .whitespaces).isEmpty:
                field = ""
                inQuotes = true
            case delimiter:
                fields.append(field)
                field = ""
            case "\r\n", "\n", "\r":
                finishRow()
                line += 1
                rowStartLine = line
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !fields.isEmpty { finishRow() }
        return rows
    }
}

public enum CSVError: Error, Equatable, Sendable {
    case unreadableEncoding
    case missingColumn(String)
}
