import Foundation

/// Plattformunabhängige Farbe für fachliche Farbcodes (z. B. Sichtungskategorien).
///
/// Die Domäne kennt weder SwiftUI noch UIKit. Oberfläche und PDF-Engine
/// wandeln diesen Wert in ihre eigenen Farbtypen um.
public struct RGBColor: Hashable, Codable, Sendable {
    /// Anteile jeweils 0…1.
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    /// Erzeugt eine Farbe aus einem Hex-Wert wie `0xD32F2F`.
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Relative Leuchtdichte nach WCAG 2.1 (0 = schwarz, 1 = weiß).
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Schwarz oder Weiß – je nachdem, was auf dieser Hintergrundfarbe besser lesbar ist.
    public var contrastingTextColor: RGBColor {
        let contrastWithBlack = (relativeLuminance + 0.05) / 0.05
        let contrastWithWhite = 1.05 / (relativeLuminance + 0.05)
        return contrastWithBlack >= contrastWithWhite ? .black : .white
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 1, green: 1, blue: 1)

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
