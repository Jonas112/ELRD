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
    /// Eigene Checkliste (Schritt 76); `nil` = Standard. Seit Schritt 78 nur noch
    /// Ausgangspunkt für `checklists`, falls dort noch nichts steht.
    public var checklist: ChecklistTemplate?
    /// Einsatzarten zur Auswahl (Schritt 78); `nil` = mitgelieferte.
    public var missionTypes: [MissionTypeSetting]?
    /// Checklisten (Schritt 78); `nil` = nur die Standardliste.
    public var checklists: [NamedChecklist]?
    /// Checkliste für Einsätze ohne Einsatzart (und Arten ohne eigene Zuordnung).
    public var defaultChecklistID: String?
    /// Führungspersonal zur Auswahl in „Führung und Kräfte“ (Schritt 81).
    public var leadershipPeople: [LeadershipPerson] = []
    /// Algorithmus der geführten Sichtung (Schritt 87).
    public var triageAlgorithm: TriageAlgorithm = .mstart
    /// Live Activity auf Sperrbildschirm und Dynamic Island (Schritt 90).
    public var showsLiveActivity: Bool = true
    /// Eigene Telefonbuch-Einträge, z. B. ILS, Polizei (Schritt 99).
    public var phoneBook: [PhoneEntry] = []
    /// Beendete Einsätze nach … Tagen anonymisieren (Schritt 102); 0 = aus.
    public var anonymizeAfterDays: Int = 0
    /// Handschuhmodus (Schritt 113): größere Tippflächen und Schrift.
    public var gloveMode: Bool = false
    /// Nachtmodus (Schritt 113): dunkel und abgedunkelt, blendfrei.
    public var nightMode: Bool = false
    /// Schritt 116: Beitritt zu eigenen geteilten Einsätzen nur nach Zulassung.
    public var requiresJoinApproval: Bool = false
    /// Schritt 120: GPX-Freigaben für Hundeteams bei Einsatzende in iCloud löschen.
    public var deletesGPXSharesOnClose: Bool = true
    /// Schritt 140: Einsätze aus Alamos FE2 über das ELRD-Backend.
    public var alamos = AlamosSettings()
    public static let anonymizeChoices = [0, 30, 90, 180, 365]

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
        missionTypes = try container.decodeIfPresent([MissionTypeSetting].self, forKey: .missionTypes)
        checklists = try container.decodeIfPresent([NamedChecklist].self, forKey: .checklists)
        defaultChecklistID = try container.decodeIfPresent(String.self, forKey: .defaultChecklistID)
        leadershipPeople = try container.decodeIfPresent([LeadershipPerson].self, forKey: .leadershipPeople) ?? []
        // Unbekannter Wert (neuere App-Version) → Standard statt Lesefehler.
        triageAlgorithm = (try? container.decodeIfPresent(TriageAlgorithm.self, forKey: .triageAlgorithm)) ?? defaults.triageAlgorithm
        showsLiveActivity = try container.decodeIfPresent(Bool.self, forKey: .showsLiveActivity) ?? defaults.showsLiveActivity
        phoneBook = try container.decodeIfPresent([PhoneEntry].self, forKey: .phoneBook) ?? []
        anonymizeAfterDays = try container.decodeIfPresent(Int.self, forKey: .anonymizeAfterDays) ?? 0
        gloveMode = try container.decodeIfPresent(Bool.self, forKey: .gloveMode) ?? false
        nightMode = try container.decodeIfPresent(Bool.self, forKey: .nightMode) ?? false
        requiresJoinApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresJoinApproval) ?? false
        deletesGPXSharesOnClose = try container.decodeIfPresent(Bool.self, forKey: .deletesGPXSharesOnClose) ?? true
        alamos = (try? container.decodeIfPresent(AlamosSettings.self, forKey: .alamos)) ?? AlamosSettings()
    }

    /// Gültige E-Mail-Form (grob: etwas@etwas.tld).
    public var hasValidILSEmail: Bool {
        let trimmed = ilsEmail.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !trimmed.contains(" ")
    }

    /// Checkliste für Einsätze ohne Einsatzart.
    public var effectiveChecklist: ChecklistTemplate { checklist(for: nil) }

    /// Einsatzarten zur Auswahl, in eingestellter Reihenfolge.
    public var effectiveMissionTypes: [MissionTypeSetting] {
        missionTypes ?? MissionType.defaultOrder.map { MissionTypeSetting(type: $0) }
    }

    /// Alle Checklisten; mindestens die Standardliste.
    public var effectiveChecklists: [NamedChecklist] {
        if let checklists, !checklists.isEmpty { return checklists }
        return [NamedChecklist(id: NamedChecklist.standardID, name: "Standard", items: (checklist ?? .standard).items)]
    }

    /// Checkliste, die für einen Einsatz gilt: die der Einsatzart, sonst die für
    /// Einsätze ohne Einsatzart, sonst die erste.
    public func namedChecklist(for type: MissionType?) -> NamedChecklist {
        let lists = effectiveChecklists
        if let type, let id = effectiveMissionTypes.first(where: { $0.type == type })?.checklistID,
           let list = lists.first(where: { $0.id == id }) {
            return list
        }
        if let id = defaultChecklistID, let list = lists.first(where: { $0.id == id }) { return list }
        return lists[0]
    }

    /// Einstellung/Vorlage einer Einsatzart (Schritt 106).
    public func template(for type: MissionType?) -> MissionTypeSetting? {
        guard let type else { return nil }
        return effectiveMissionTypes.first { $0.type == type }
    }

    public func checklist(for type: MissionType?) -> ChecklistTemplate {
        namedChecklist(for: type).template
    }

    /// Auswahl für einen Einsatz: eingestellte Arten plus seine eigene, falls sie fehlt.
    public func missionTypeChoices(including current: MissionType?) -> [MissionType] {
        var types = effectiveMissionTypes.map(\.type)
        if let current, !types.contains(current) { types.append(current) }
        return types
    }

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
    /// Mitteilungen, auch bei gesperrtem Gerät (Schritt 83).
    public var notifiesWhenLocked: Bool = true
    /// Nachsichtung fällig nach … (Schritt 95), 0 = aus.
    public var retriageMinutesSK2: Int = 30
    public var retriageMinutesSK3: Int = 60
    /// Arten offener Punkte, die nicht angezeigt werden (Schlüssel, Schritt 96).
    public var hiddenOpenItemKinds: [String] = []
    /// Automatisches Lagebild ins Tagebuch alle … Minuten (Schritt 109), 0 = aus.
    public var situationSnapshotMinutes: Int = 0

    /// Nachsichtungsfrist einer Kategorie (nur SK 2 und SK 3).
    public func retriageMinutes(for triage: Sichtungskategorie) -> Int {
        switch triage {
        case .sk2: retriageMinutesSK2
        case .sk3: retriageMinutesSK3
        default: 0
        }
    }

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
        notifiesWhenLocked = try container.decodeIfPresent(Bool.self, forKey: .notifiesWhenLocked) ?? defaults.notifiesWhenLocked
        retriageMinutesSK2 = try container.decodeIfPresent(Int.self, forKey: .retriageMinutesSK2) ?? defaults.retriageMinutesSK2
        retriageMinutesSK3 = try container.decodeIfPresent(Int.self, forKey: .retriageMinutesSK3) ?? defaults.retriageMinutesSK3
        hiddenOpenItemKinds = try container.decodeIfPresent([String].self, forKey: .hiddenOpenItemKinds) ?? []
        situationSnapshotMinutes = try container.decodeIfPresent(Int.self, forKey: .situationSnapshotMinutes) ?? defaults.situationSnapshotMinutes
    }

    /// Auswahl in den Einstellungen.
    public static let choices = [0, 10, 15, 20, 30, 45, 60]
    /// Auswahl für automatische Lagebilder.
    public static let snapshotChoices = [0, 15, 30, 60]
}

/// Eintrag im Telefonbuch (Schritt 99).
public struct PhoneEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var number: String

    public init(id: UUID = UUID(), name: String, number: String) {
        self.id = id
        self.name = name
        self.number = number
    }

    /// `tel:`-Adresse (nur Ziffern und +), `nil` ohne Nummer.
    public static func telURL(_ number: String) -> URL? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 3 else { return nil }
        return URL(string: "tel:\(digits)")
    }
}
