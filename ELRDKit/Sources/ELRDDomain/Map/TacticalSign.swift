import Foundation

// MARK: - Taktische Zeichen (Schritt 114)

/// Grundzeichen nach DV 102 / „Taktische Zeichen im Bevölkerungsschutz“.
public enum TacticalBase: String, CaseIterable, Sendable {
    case taktischeFormation
    case befehlsstelle
    case stelle
    case gebaeude
    case fahrzeug
    case kraftfahrzeug
    case hubschrauber
    case person
    case personVerletzt
    case personTot
    case personZuTransportieren
    case gefahr
    case gefahrAkut
    case massnahme
}

/// Organisation, bestimmt die Füllfarbe.
public enum TacticalOrganisation: String, CaseIterable, Sendable, DisplayNamed {
    case hilfsorganisation
    case feuerwehr
    case thw
    case polizei
    case fuehrung
    case gefahrenabwehr
    case bundeswehr
    case zivil

    public var displayName: String {
        switch self {
        case .hilfsorganisation: "Hilfsorganisation / Rettungsdienst"
        case .feuerwehr: "Feuerwehr"
        case .thw: "THW"
        case .polizei: "Polizei"
        case .fuehrung: "Führung"
        case .gefahrenabwehr: "Sonstige Gefahrenabwehr"
        case .bundeswehr: "Bundeswehr"
        case .zivil: "Zivile Einheiten"
        }
    }

    /// Füllfarbe nach DV 102.
    public var fill: RGBColor {
        switch self {
        case .hilfsorganisation: RGBColor(hex: 0xFFFFFF)
        case .feuerwehr: RGBColor(hex: 0xFA321E)
        case .thw: RGBColor(hex: 0x003399)
        case .polizei: RGBColor(hex: 0x64DC32)
        case .fuehrung: RGBColor(hex: 0xFAFA00)
        case .gefahrenabwehr: RGBColor(hex: 0xFA8C00)
        case .bundeswehr: RGBColor(hex: 0xB4783C)
        case .zivil: RGBColor(hex: 0xBEBEBE)
        }
    }

    /// Schrift und Linien auf der Füllfarbe.
    public var usesWhiteInk: Bool {
        switch self {
        case .feuerwehr, .thw, .bundeswehr, .zivil: true
        default: false
        }
    }
}

/// Fachaufgabe im Zeichen (nur die für den Rettungsdienst wichtigen).
public enum TacticalTask: String, CaseIterable, Sendable {
    /// Rettungs-, Sanitäts-, Gesundheitswesen: Kreuz über die ganze Fläche.
    case rettungswesen
    /// Ärztliche Versorgung: Kreuz mit zusätzlichem Querstrich unten.
    case aerztlicheVersorgung
    /// Krankenhaus: Kreuz mit zwei senkrechten Strichen.
    case krankenhaus
}

/// Stärke einer Einheit (Punkte bzw. Striche über dem Zeichen).
public enum TacticalUnitSize: String, CaseIterable, Sendable, DisplayNamed {
    case trupp, staffel, gruppe, zug

    public var displayName: String {
        switch self {
        case .trupp: "Trupp"
        case .staffel: "Staffel"
        case .gruppe: "Gruppe"
        case .zug: "Zug"
        }
    }
}

/// Taktisches Zeichen eines Kartenobjekts. Bestandteile als Text gespeichert:
/// Werte einer neueren App bleiben lesbar und werden als Standard gezeichnet.
public struct TacticalSign: Hashable, Codable, Sendable {
    public var baseRaw: String
    public var organisationRaw: String
    public var taskRaw: String?
    public var unitSizeRaw: String?
    /// Kurztext im Zeichen, z. B. „RTW“, „BR“, „ELRD“.
    public var text: String
    /// Vorlage, aus der das Zeichen stammt (für die Auswahl).
    public var presetID: String?

    public init(base: TacticalBase, organisation: TacticalOrganisation, task: TacticalTask? = nil,
                unitSize: TacticalUnitSize? = nil, text: String = "", presetID: String? = nil) {
        baseRaw = base.rawValue
        organisationRaw = organisation.rawValue
        taskRaw = task?.rawValue
        unitSizeRaw = unitSize?.rawValue
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        self.presetID = presetID
    }

    public var base: TacticalBase { TacticalBase(rawValue: baseRaw) ?? .stelle }
    public var organisation: TacticalOrganisation { TacticalOrganisation(rawValue: organisationRaw) ?? .hilfsorganisation }
    public var task: TacticalTask? { taskRaw.flatMap(TacticalTask.init(rawValue:)) }
    public var unitSize: TacticalUnitSize? { unitSizeRaw.flatMap(TacticalUnitSize.init(rawValue:)) }

    /// Gefahren sind immer rot umrandet (keine Organisationsfarbe).
    public var isHazard: Bool { base == .gefahr || base == .gefahrAkut }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseRaw = try container.decodeIfPresent(String.self, forKey: .baseRaw) ?? TacticalBase.stelle.rawValue
        organisationRaw = try container.decodeIfPresent(String.self, forKey: .organisationRaw) ?? TacticalOrganisation.hilfsorganisation.rawValue
        taskRaw = try container.decodeIfPresent(String.self, forKey: .taskRaw)
        unitSizeRaw = try container.decodeIfPresent(String.self, forKey: .unitSizeRaw)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
    }
}

/// Vorlage zum Antippen. Vorschlag von Claude nach DV 102, fachlich von Jonas zu
/// prüfen (E115) – Korrekturen nur hier in den Daten.
public struct TacticalSignPreset: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case fahrzeuge = "Fahrzeuge"
        case fuehrung = "Führung"
        case stellen = "Stellen und Einrichtungen"
        case personen = "Personen"
        case gefahren = "Gefahren"
    }

    public let id: String
    public let title: String
    public let group: Group
    public let sign: TacticalSign

    init(_ id: String, _ title: String, _ group: Group, _ base: TacticalBase, _ organisation: TacticalOrganisation,
         task: TacticalTask? = nil, unitSize: TacticalUnitSize? = nil, text: String = "") {
        self.id = id
        self.title = title
        self.group = group
        sign = TacticalSign(base: base, organisation: organisation, task: task, unitSize: unitSize, text: text, presetID: id)
    }

    public static let all: [TacticalSignPreset] = [
        .init("rtw", "Rettungswagen (RTW)", .fahrzeuge, .kraftfahrzeug, .hilfsorganisation, task: .rettungswesen, text: "RTW"),
        .init("nef", "Notarzteinsatzfahrzeug (NEF)", .fahrzeuge, .kraftfahrzeug, .hilfsorganisation, task: .aerztlicheVersorgung, text: "NEF"),
        .init("ktw", "Krankentransportwagen (KTW)", .fahrzeuge, .kraftfahrzeug, .hilfsorganisation, task: .rettungswesen, text: "KTW"),
        .init("rth", "Rettungshubschrauber (RTH)", .fahrzeuge, .hubschrauber, .hilfsorganisation, text: "RTH"),
        .init("seg", "Schnelleinsatzgruppe (SEG)", .fahrzeuge, .taktischeFormation, .hilfsorganisation, task: .rettungswesen, unitSize: .gruppe, text: "SEG"),
        .init("fw", "Feuerwehr-Fahrzeug", .fahrzeuge, .kraftfahrzeug, .feuerwehr, text: "LF"),
        .init("pol", "Polizei-Fahrzeug", .fahrzeuge, .kraftfahrzeug, .polizei, text: "FuStW"),
        .init("thw", "THW-Fahrzeug", .fahrzeuge, .kraftfahrzeug, .thw, text: "GKW"),
        .init("elrd", "Einsatzleitung Rettungsdienst", .fuehrung, .befehlsstelle, .fuehrung, task: .rettungswesen, text: "ELRD"),
        .init("tel", "Technische Einsatzleitung", .fuehrung, .befehlsstelle, .fuehrung, text: "TEL"),
        .init("ea", "Einsatzabschnittsleitung", .fuehrung, .befehlsstelle, .fuehrung, text: "EA"),
        .init("br", "Bereitstellungsraum", .stellen, .stelle, .hilfsorganisation, text: "BR"),
        .init("pa", "Patientenablage", .stellen, .stelle, .hilfsorganisation, task: .rettungswesen, text: "PA"),
        .init("bhp", "Behandlungsplatz", .stellen, .stelle, .hilfsorganisation, task: .aerztlicheVersorgung, text: "BHP"),
        .init("sammel", "Sammelstelle Betroffene", .stellen, .stelle, .hilfsorganisation, text: "SB"),
        .init("lp", "Landeplatz Hubschrauber", .stellen, .stelle, .hilfsorganisation, text: "H"),
        .init("kh", "Krankenhaus", .stellen, .gebaeude, .hilfsorganisation, task: .krankenhaus),
        .init("verletzt", "Verletzte Person", .personen, .personVerletzt, .hilfsorganisation),
        .init("tot", "Tote Person", .personen, .personTot, .hilfsorganisation),
        .init("transport", "Person zu transportieren", .personen, .personZuTransportieren, .hilfsorganisation),
        .init("gefahr", "Gefahr", .gefahren, .gefahr, .hilfsorganisation),
        .init("gefahrAkut", "Akute Gefahr", .gefahren, .gefahrAkut, .hilfsorganisation),
        .init("massnahme", "Maßnahme", .gefahren, .massnahme, .hilfsorganisation),
    ]

    public static func preset(_ id: String?) -> TacticalSignPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
