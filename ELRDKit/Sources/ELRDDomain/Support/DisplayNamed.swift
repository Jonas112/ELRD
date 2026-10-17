/// Typen mit einer deutschen Anzeigebezeichnung für Oberfläche und Berichte.
public protocol DisplayNamed {
    /// Ausführliche Bezeichnung, z. B. „Sichtungskategorie 1“.
    var displayName: String { get }
    /// Kurzform für Tabellen und Badges, z. B. „SK 1“.
    var shortName: String { get }
}

public extension DisplayNamed {
    var shortName: String { displayName }
}
