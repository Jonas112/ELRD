/// Geschlecht eines Patienten. Rohwerte wie ELRDRG (`Victim.gender`).
public enum Gender: Int, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case unklar = -1
    case maennlich = 0
    case weiblich = 1

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .unklar: "Unklar"
        case .maennlich: "Männlich"
        case .weiblich: "Weiblich"
        }
    }

    public var shortName: String {
        switch self {
        case .unklar: "?"
        case .maennlich: "m"
        case .weiblich: "w"
        }
    }
}

/// Schockraum-Anforderung. Rohwerte wie ELRDRG (`Victim.traumaRoom`).
public enum TraumaRoom: Int, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case none = 0
    case a = 1
    case b = 2

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Kein Schockraum"
        case .a: "Schockraum A"
        case .b: "Schockraum B"
        }
    }

    public var shortName: String {
        switch self {
        case .none: "–"
        case .a: "SR A"
        case .b: "SR B"
        }
    }
}

/// Stand der Anmeldung in der Zielklinik. Rohwerte wie ELRDRG (`Victim.hospitalClearance`).
public enum HospitalRegistrationState: Int, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case unklar = 0
    case angefragt = 1
    case angemeldet = 2
    case nichtAngefragt = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .unklar: "Unklar"
        case .angefragt: "Klinik angefragt"
        case .angemeldet: "Patient angemeldet"
        case .nichtAngefragt: "Klinik nicht angefragt"
        }
    }

    public var shortName: String {
        switch self {
        case .unklar: "–"
        case .angefragt: "angefragt"
        case .angemeldet: "angemeldet"
        case .nichtAngefragt: "nicht angefragt"
        }
    }

    /// Ampelfarbe wie in ELRDRG: offen = rot, angefragt = orange, angemeldet = grün.
    public var color: RGBColor {
        switch self {
        case .unklar, .nichtAngefragt: RGBColor(hex: 0xD32F2F)
        case .angefragt: RGBColor(hex: 0xF57C00)
        case .angemeldet: RGBColor(hex: 0x388E3C)
        }
    }
}

/// Körperregion einer Verletzung. Rohwerte und Texte wie ELRDRG (`InjuryHandler.locations`).
public enum BodyRegion: Int, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case arm = 0
    case oberschenkel = 1
    case unterschenkel = 2
    case hand = 3
    case abdomen = 4
    case thorax = 5
    case kopf = 6
    case wirbelsaeule = 7

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .arm: "Arm"
        case .oberschenkel: "Oberschenkel"
        case .unterschenkel: "Unterschenkel"
        case .hand: "Hand"
        case .abdomen: "Abdomen"
        case .thorax: "Thorax"
        case .kopf: "Kopf"
        case .wirbelsaeule: "Wirbelsäule"
        }
    }

    /// Ob für diese Region eine Körperseite angegeben werden kann.
    public var hasSide: Bool {
        switch self {
        case .arm, .oberschenkel, .unterschenkel, .hand: true
        case .abdomen, .thorax, .kopf, .wirbelsaeule: false
        }
    }

    /// Liest den in ELRDRG als Text gespeicherten Ort.
    public init?(legacyText: String?) {
        guard let text = legacyText else { return nil }
        guard let match = Self.allCases.first(where: { $0.displayName == text }) else { return nil }
        self = match
    }
}

/// Körperseite. Rohwerte wie ELRDRG (`InjuryHandler.side`).
public enum BodySide: Int, CaseIterable, Codable, Sendable, Identifiable, DisplayNamed {
    case links = 0
    case rechts = 1

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .links: "links"
        case .rechts: "rechts"
        }
    }
}
