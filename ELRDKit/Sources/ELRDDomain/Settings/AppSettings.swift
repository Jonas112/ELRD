import Foundation

/// Einstellungen des Geräts bzw. der Organisation (Schritt 47), als ein Dokument
/// gespeichert. Neue Felder nur mit Standardwert – ältere Dokumente bleiben lesbar.
public struct AppSettings: Codable, Hashable, Sendable {
    /// Name der Organisation, z. B. „BRK Kreisverband Schweinfurt“ (Banner, Berichtskopf).
    public var organisationName: String = ""
    /// Banner-/Logobild (Startseite, Berichtskopf).
    public var bannerImage: Data?
    /// E-Mail-Adresse der Leitstelle für „Bericht an ILS“.
    public var ilsEmail: String = ""
    /// Vorlage, mit der der Berichts-Editor startet.
    public var defaultReportTemplateID: UUID?
    /// Eigene Fahrzeugbilder je Einheitentyp (Rohwert), wie ELRDRG `imageRTW` usw.
    public var unitTypeImages: [Int: Data] = [:]
    /// IVENA-Angaben (PZC, Dringlichkeit, ABCD) beim Patienten zeigen (Schritt 49).
    /// Der RMI-Katalog selbst gehört zu den Stammdaten (`MasterDataSet.ivenaCatalogID`).
    public var showsIVENA: Bool = true
    /// Angenommene Fassung der Vereinbarungen (Schritt 50).
    public var acceptedAgreementVersion: Int?
    public var acceptedAgreementAt: Date?
    /// Einführung gesehen.
    public var hasCompletedOnboarding: Bool = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        organisationName = try container.decodeIfPresent(String.self, forKey: .organisationName) ?? defaults.organisationName
        bannerImage = try container.decodeIfPresent(Data.self, forKey: .bannerImage)
        ilsEmail = try container.decodeIfPresent(String.self, forKey: .ilsEmail) ?? defaults.ilsEmail
        defaultReportTemplateID = try container.decodeIfPresent(UUID.self, forKey: .defaultReportTemplateID)
        unitTypeImages = try container.decodeIfPresent([Int: Data].self, forKey: .unitTypeImages) ?? defaults.unitTypeImages
        showsIVENA = try container.decodeIfPresent(Bool.self, forKey: .showsIVENA) ?? defaults.showsIVENA
        acceptedAgreementVersion = try container.decodeIfPresent(Int.self, forKey: .acceptedAgreementVersion)
        acceptedAgreementAt = try container.decodeIfPresent(Date.self, forKey: .acceptedAgreementAt)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding
    }

    /// Gültige E-Mail-Form (grob: etwas@etwas.tld).
    public var hasValidILSEmail: Bool {
        let trimmed = ilsEmail.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !trimmed.contains(" ")
    }

    public func image(for type: UnitType) -> Data? {
        unitTypeImages[type.rawValue]
    }
}
