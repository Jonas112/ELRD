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
    /// Erinnerungen (Schritt 69).
    public var reminders = ReminderSettings()
    /// Eigene Checkliste (Schritt 76); `nil` = Standard.
    public var checklist: ChecklistTemplate?

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
        reminders = try container.decodeIfPresent(ReminderSettings.self, forKey: .reminders) ?? defaults.reminders
        checklist = try container.decodeIfPresent(ChecklistTemplate.self, forKey: .checklist)
    }

    /// Gültige E-Mail-Form (grob: etwas@etwas.tld).
    public var hasValidILSEmail: Bool {
        let trimmed = ilsEmail.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !trimmed.contains(" ")
    }

    /// Checkliste, die gilt (eigene oder Standard).
    public var effectiveChecklist: ChecklistTemplate { checklist ?? .standard }

    public func image(for type: UnitType) -> Data? {
        unitTypeImages[type.rawValue]
    }
}

/// Wann die App an etwas erinnert (Minuten; 0 = aus).
public struct ReminderSettings: Codable, Hashable, Sendable {
    /// Lagemeldung an die ILS im Takt.
    public var situationReportMinutes: Int = 30
    /// Patient wartet ohne Transportmittel länger als …
    public var transportWaitMinutes: Int = 20
    /// Platzhalter ohne Fahrzeug länger als …
    public var placeholderMinutes: Int = 15

    public init(situationReportMinutes: Int = 30, transportWaitMinutes: Int = 20, placeholderMinutes: Int = 15) {
        self.situationReportMinutes = situationReportMinutes
        self.transportWaitMinutes = transportWaitMinutes
        self.placeholderMinutes = placeholderMinutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReminderSettings()
        situationReportMinutes = try container.decodeIfPresent(Int.self, forKey: .situationReportMinutes) ?? defaults.situationReportMinutes
        transportWaitMinutes = try container.decodeIfPresent(Int.self, forKey: .transportWaitMinutes) ?? defaults.transportWaitMinutes
        placeholderMinutes = try container.decodeIfPresent(Int.self, forKey: .placeholderMinutes) ?? defaults.placeholderMinutes
    }

    /// Auswahl in den Einstellungen.
    public static let choices = [0, 10, 15, 20, 30, 45, 60]
}

