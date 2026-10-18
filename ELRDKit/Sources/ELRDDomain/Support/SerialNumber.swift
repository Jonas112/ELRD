import Foundation

/// Laufende Nummer mit Gerätepräfix, z. B. „A-12“ (Patient) oder „B-3“ (Tagebuch).
///
/// Jedes Gerät vergibt Nummern nur mit seinem eigenen Buchstaben. Dadurch können
/// mehrere Geräte offline gleichzeitig im selben Einsatz arbeiten, ohne dass
/// Nummern doppelt entstehen (Entscheidung E26). Ein leeres Präfix steht für
/// Nummern ohne Gerätezuordnung, z. B. aus übernommenen Altdaten.
///
/// In JSON als Text gespeichert („A-12“), damit Backend und Berichte ihn direkt lesen.
public struct SerialNumber: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Leer oder 1–2 Großbuchstaben A–Z.
    public let prefix: String
    /// Ab 1.
    public let value: Int

    /// `nil` bei ungültigem Präfix oder Wert < 1.
    public init?(prefix: String, value: Int) {
        let normalized = prefix.uppercased()
        guard SerialNumber.isValidPrefix(normalized) || normalized.isEmpty, value >= 1 else { return nil }
        self.prefix = normalized
        self.value = value
    }

    /// Liest „A-12“, „a12“, „AB-7“ oder „12“ (ohne Präfix). Leerraum wird ignoriert.
    public init?(parsing text: String) {
        let compact = text.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
        let letters = compact.prefix(while: { $0.isLetter })
        let digits = compact.dropFirst(letters.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let value = Int(digits) else { return nil }
        self.init(prefix: String(letters), value: value)
    }

    public var description: String {
        prefix.isEmpty ? String(value) : "\(prefix)-\(value)"
    }

    /// Sortierung: erst nach Präfix, dann numerisch (A-2 vor A-10 vor B-1).
    public static func < (lhs: SerialNumber, rhs: SerialNumber) -> Bool {
        (lhs.prefix, lhs.value) < (rhs.prefix, rhs.value)
    }

    /// 1–2 Großbuchstaben A–Z (keine Umlaute, damit Anhängekarten eindeutig lesbar bleiben).
    public static func isValidPrefix(_ prefix: String) -> Bool {
        (1...2).contains(prefix.count) && prefix.allSatisfy { ("A"..."Z").contains($0) }
    }

    /// Nächste Nummer für ein Gerätepräfix: höchste vorhandene mit diesem Präfix + 1.
    /// Nummern anderer Geräte bleiben unberührt.
    public static func next(prefix: String, existing numbers: some Sequence<SerialNumber>) -> SerialNumber {
        let normalized = prefix.uppercased()
        let highest = numbers.filter { $0.prefix == normalized }.map(\.value).max() ?? 0
        // Präfix stammt aus einer geprüften Geräteidentität; Fallback ohne Präfix nur bei Fehlbedienung.
        return SerialNumber(prefix: normalized, value: highest + 1)
            ?? SerialNumber(prefix: "", value: highest + 1)!
    }
}

extension SerialNumber: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self), let serial = SerialNumber(prefix: "", value: number) {
            self = serial
            return
        }
        let text = try container.decode(String.self)
        guard let serial = SerialNumber(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ungültige Nummer: \(text)")
        }
        self = serial
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension SerialNumber: ExpressibleByIntegerLiteral {
    /// Nummer ohne Präfix, z. B. für Altdaten und Tests. Werte < 1 werden zu 1.
    public init(integerLiteral value: Int) {
        self = SerialNumber(prefix: "", value: max(value, 1))!
    }
}

/// Identität dieses Geräts im Mehrbenutzer-Modus.
public struct DeviceIdentity: Hashable, Codable, Sendable {
    public let deviceID: DeviceID
    /// Buchstabe(n) für Patienten- und Tagebuchnummern dieses Geräts.
    public let numberPrefix: String

    /// `nil` bei ungültigem Präfix (siehe `SerialNumber.isValidPrefix`).
    public init?(deviceID: DeviceID, numberPrefix: String) {
        let normalized = numberPrefix.uppercased()
        guard SerialNumber.isValidPrefix(normalized) else { return nil }
        self.deviceID = deviceID
        self.numberPrefix = normalized
    }

    /// Standard für ein einzelnes Gerät.
    public static let defaultPrefix = "A"
}
