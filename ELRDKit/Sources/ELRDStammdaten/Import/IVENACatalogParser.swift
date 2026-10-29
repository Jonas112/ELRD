import Foundation
import ELRDDomain

/// Liest IVENA-Kataloge.
///
/// Zwei Formate:
/// - Tabulatorgetrennt: `NNN<TAB>Titel<TAB>Kategorie` (eindeutig, bevorzugt).
/// - Textformat der ELRDRG-Datei: `NNN - Titel - Kategorie`, optional mit Sichtungshinweis
/// `NNN - Titel - 21x Mehrfach (SK 1+2)`. Titel und Kategorie dürfen selbst
/// „ - “ enthalten (z. B. „Mund - Kiefer - Gesicht“). Die Kategorie beginnt
/// beim letzten Abschnitt der Form „21x …“; fehlt dieser, beim letzten „ - “.
public enum IVENACatalogParser {
    public static func parse(_ text: String) -> ImportResult<RMI> {
        var result = ImportResult<RMI>()
        var codes = Set<Int>()
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let entry = parseLine(line) else {
                result.issues.append(ImportIssue(line: offset + 1, message: "Format nicht erkannt"))
                continue
            }
            guard codes.insert(entry.code).inserted else {
                result.issues.append(ImportIssue(line: offset + 1, message: "RMI \(entry.code) doppelt"))
                continue
            }
            result.items.append(entry)
        }
        return result
    }

    static func parseLine(_ line: String) -> RMI? {
        if line.contains("\t") { return parseTabSeparated(line) }
        let parts = line.components(separatedBy: " - ")
        guard parts.count >= 3, let code = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              (100...999).contains(code) else { return nil }

        let rest = Array(parts.dropFirst())
        let categoryStart = rest.lastIndex { $0.range(of: #"^\d{1,2}x "#, options: .regularExpression) != nil }
            ?? rest.index(before: rest.endIndex)
        guard categoryStart > rest.startIndex else { return nil }

        let title = rest[..<categoryStart].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        var category = rest[categoryStart...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        var hint: String?
        if let range = category.range(of: #"\s*\((SK [^)]*)\)$"#, options: .regularExpression) {
            hint = String(category[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            category.removeSubrange(range)
        }
        guard !title.isEmpty, !category.isEmpty else { return nil }
        return RMI(code: code, title: title, category: category, triageHint: hint)
    }

    static func parseTabSeparated(_ line: String) -> RMI? {
        let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let code = Int(parts[0]), (100...999).contains(code),
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        let hint = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
        return RMI(code: code, title: parts[1], category: parts[2], triageHint: hint)
    }
}
