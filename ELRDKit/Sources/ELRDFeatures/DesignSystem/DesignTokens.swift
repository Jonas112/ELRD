import SwiftUI
import Observation
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

/// Eckenradien – nur diese Werte verwenden (Schritt 127, E121).
public enum Radius {
    /// Kleine Marken (SK-Badge, Kürzel).
    public static let chip: CGFloat = 6
    /// Eingabefelder, kleine Knöpfe, Zeilen.
    public static let control: CGFloat = 10
    /// Karten und Listenblöcke.
    public static let card: CGFloat = 14
    /// Große Knöpfe und Auswahlkacheln.
    public static let large: CGFloat = 20
    /// Startkacheln (Neuer Einsatz, Anmelden).
    public static let hero: CGFloat = 28
}

/// Mindestgröße für Tippflächen (Apple HIG: 44 pt; im Einsatz mit Handschuhen eher mehr).
/// Im Handschuhmodus (Schritt 113) um ein Drittel größer; Ansichten, die die Werte
/// lesen, werden über `DisplayMode` beim Umschalten neu gezeichnet.
public enum TouchTarget {
    public static var minimum: CGFloat { 44 * DisplayMode.shared.touchScale }
    public static var comfortable: CGFloat { 56 * DisplayMode.shared.touchScale }
    /// Hauptaktionen, die man auch verschlafen sofort trifft („Einsatz starten“).
    public static var large: CGFloat { 72 * DisplayMode.shared.touchScale }
}

/// Darstellungsmodus aus den Einstellungen (Schritt 113). Beobachtbar, damit jede
/// Ansicht, die `TouchTarget` liest, beim Umschalten neu gezeichnet wird.
@Observable
public final class DisplayMode: @unchecked Sendable {
    public static let shared = DisplayMode()

    public internal(set) var isGloveMode = false
    public internal(set) var isNightMode = false

    private init() {}

    /// Faktor für Tippflächen.
    public var touchScale: CGFloat { isGloveMode ? 1.3 : 1 }

    func apply(_ settings: AppSettings) {
        if isGloveMode != settings.gloveMode { isGloveMode = settings.gloveMode }
        if isNightMode != settings.nightMode { isNightMode = settings.nightMode }
    }
}

/// Flächen für Hauptaktionen (gefüllte Knöpfe mit weißer Schrift).
///
/// Die Akzentfarbe selbst ist im dunklen Modus hell (#5C9DFF) und eignet sich
/// nur für Text und Symbole; weiße Schrift darauf wäre zu kontrastarm.
public enum ActionFill {
    public static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2F / 255, green: 0x6F / 255, blue: 0xD6 / 255, alpha: 1)
            : UIColor(red: 0x1F / 255, green: 0x5F / 255, blue: 0xAD / 255, alpha: 1)
    })
    /// Ausgewählter Zustand von Auswahlknöpfen (Hintergrund).
    public static let selected = Color.accentColor.opacity(0.22)
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

    /// IVENA-Behandlungsdringlichkeit wie in IVENA: 1 rot, 2 gelb/orange, 3 grün.
    static func treatmentPriority(_ priority: TreatmentPriority) -> Color {
        switch priority {
        case .sofortigeIntervention: Color(RGBColor(hex: 0xD32F2F))
        case .stationaereAufnahmeWahrscheinlich: Color(RGBColor(hex: 0xF57C00))
        case .vermutlichAmbulant: Color(RGBColor(hex: 0x2E7D32))
        case .keineDringlichkeit: Color(RGBColor(hex: 0x8E8E93))
        }
    }
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

public extension View {
    /// Schritt 128 (E122): kleines Blatt für wenig Inhalt (Nachrichten, Neuer
    /// Eintrag, Checkliste) – auf dem iPad als Formularblatt statt Seitengröße.
    @ViewBuilder
    func formSheet() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.form)
        } else {
            self
        }
    }

    /// Blatt in Seitengröße statt kleinem Formularblatt (iPadOS 18+); weniger Scrollen.
    @ViewBuilder
    func largeSheet() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}
