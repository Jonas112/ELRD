import SwiftUI
import UIKit
import ELRDDomain

/// Abstände im Raster von 4 pt. Überall diese Werte statt freier Zahlen verwenden.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Eckenradien.
public enum Radius {
    public static let chip: CGFloat = 6
    public static let control: CGFloat = 10
    public static let card: CGFloat = 14
}

/// Mindestgröße für Tippflächen (Apple HIG: 44 pt; im Einsatz mit Handschuhen eher mehr).
public enum TouchTarget {
    public static let minimum: CGFloat = 44
    public static let comfortable: CGFloat = 56
}

public extension Color {
    /// Farbe aus der plattformunabhängigen Domänenfarbe.
    init(_ rgb: RGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// Kennfarbe einer Sichtungskategorie (in hellem und dunklem Modus gleich –
    /// die Farbe ist ein fachlicher Code, kein Gestaltungselement).
    static func triage(_ category: Sichtungskategorie) -> Color { Color(category.color) }

    /// Gut lesbare Schriftfarbe auf der Kennfarbe.
    static func onTriage(_ category: Sichtungskategorie) -> Color { Color(category.color.contrastingTextColor) }

    /// Ampelfarbe für den Klinik-Anmeldestatus.
    static func registration(_ state: HospitalRegistrationState) -> Color { Color(state.color) }
}

/// Hintergründe als System-Farben, damit hell/dunkel und erhöhter Kontrast stimmen.
public enum Surface {
    public static let canvas = Color(uiColor: .systemGroupedBackground)
    public static let card = Color(uiColor: .secondarySystemGroupedBackground)
    public static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
    public static let separator = Color(uiColor: .separator)
}

/// Karten-Optik für Inhaltsblöcke.
public struct CardStyle: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(Spacing.l)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

public extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}
