import Foundation

/// Herkunft eines Stammdateneintrags.
public enum MasterDataOrigin: Hashable, Codable, Sendable {
    /// Aus einem Regionspaket importiert (Kennung der Region, z. B. „coburg“).
    case region(String)
    /// Von Hand in den Stammdaten angelegt.
    case manual
    /// Während eines Einsatzes angelegt und dauerhaft übernommen
    /// (ELRDRG: „temporäre Einheit speichern“).
    case fromMission
}

public extension MasterDataOrigin {
    /// Kennung der Region, falls aus einem Regionspaket.
    var regionID: String? {
        if case .region(let id) = self { return id }
        return nil
    }
}

/// Einheit in den Stammdaten (Vorlage für Einsatzeinheiten).
public struct MasterUnit: Identifiable, Hashable, Codable, Sendable {
    public let id: MasterUnitID
    public var callsign: String
    public var type: UnitType
    /// Ursprüngliche Typbezeichnung, falls genauer als `type` (z. B. „HVO“, „MZF“).
    public var typeLabel: String?
    public var crewCount: Int?
    public var origin: MasterDataOrigin

    public init(
        id: MasterUnitID = MasterUnitID(),
        callsign: String,
        type: UnitType,
        typeLabel: String? = nil,
        crewCount: Int? = nil,
        origin: MasterDataOrigin = .manual
    ) {
        self.id = id
        self.callsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        self.type = type
        let label = typeLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRedundant = label?.uppercased() == type.shortName.uppercased()
        self.typeLabel = (label?.isEmpty ?? true) || isRedundant ? nil : label
        self.crewCount = crewCount.flatMap { $0 > 0 ? $0 : nil }
        self.origin = origin
    }

    /// Typ zur Anzeige: Originalbezeichnung, sonst Kurzname des Typs.
    public var typeDisplayName: String { typeLabel ?? type.shortName }

    /// Schlüssel zum Erkennen von Doppelten (Groß/klein und Leerraum egal).
    public var matchKey: String { MasterDataMatching.key(callsign) }

    /// Erzeugt die Einsatzeinheit zu diesem Stammdateneintrag.
    public func makeMissionUnit(missionID: MissionID, metadata: EntityMetadata, sectionID: SectionID?) -> MissionUnit {
        MissionUnit(
            missionID: missionID,
            metadata: metadata,
            type: type,
            callsign: callsign,
            crewCount: crewCount,
            masterUnitID: id,
            sectionID: sectionID
        )
    }
}

/// Klinik in den Stammdaten.
public struct MasterHospital: Identifiable, Hashable, Codable, Sendable {
    public let id: MasterHospitalID
    public var name: String
    public var address: String
    public var city: String
    public var phone: String
    public var email: String
    /// Eigene Adresse für Patientenanmeldungen, falls abweichend (Dachau-Liste).
    public var registrationEmail: String?
    public var coordinate: GeoCoordinate?
    public var origin: MasterDataOrigin

    public init(
        id: MasterHospitalID = MasterHospitalID(),
        name: String,
        address: String = "",
        city: String = "",
        phone: String = "",
        email: String = "",
        registrationEmail: String? = nil,
        coordinate: GeoCoordinate? = nil,
        origin: MasterDataOrigin = .manual
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let registration = registrationEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.registrationEmail = (registration?.isEmpty ?? true) ? nil : registration
        self.coordinate = coordinate
        self.origin = origin
    }

    /// Schlüssel zum Erkennen von Doppelten: Name und Ort.
    public var matchKey: String { MasterDataMatching.key(name + "|" + city) }

    /// Momentaufnahme für die Zielklinik eines Patienten.
    public var snapshot: HospitalSnapshot {
        HospitalSnapshot(
            name: name,
            address: address,
            city: city,
            phone: phone,
            email: registrationEmail ?? email,
            coordinate: coordinate,
            masterHospitalID: id
        )
    }
}

/// Diagnose im Katalog, optional einer Körperregion zugeordnet.
public struct MasterInjury: Identifiable, Hashable, Codable, Sendable {
    public let id: MasterInjuryID
    public var diagnosis: String
    public var region: BodyRegion?
    public var origin: MasterDataOrigin

    public init(id: MasterInjuryID = MasterInjuryID(), diagnosis: String, region: BodyRegion?, origin: MasterDataOrigin = .manual) {
        self.id = id
        self.diagnosis = diagnosis.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        self.origin = origin
    }

    public var matchKey: String { MasterDataMatching.key("\(region?.rawValue ?? -1)|\(diagnosis)") }

    /// Erzeugt die Verletzung für einen Patienten (Seite wählt der Benutzer).
    public func makeInjury(side: BodySide?) -> Injury {
        Injury(diagnosis: diagnosis, region: region, side: side, masterInjuryID: id)
    }
}

/// Abschnittsvorlage in den Stammdaten.
public struct MasterSection: Identifiable, Hashable, Codable, Sendable {
    public let id: MasterSectionID
    public var name: String
    public var sortIndex: Int
    /// Wird bei jedem neuen Einsatz automatisch angelegt (ELRDRG: „allwaysExits“).
    public var addAutomatically: Bool
    /// Wird im Einsatz zum Initialabschnitt.
    public var isInitial: Bool

    public init(id: MasterSectionID = MasterSectionID(), name: String, sortIndex: Int, addAutomatically: Bool = false, isInitial: Bool = false) {
        self.id = id
        self.name = MissionSection.normalizedName(name)
        self.sortIndex = sortIndex
        self.addAutomatically = addAutomatically
        self.isInitial = isInitial
    }

    public var matchKey: String { MasterDataMatching.key(name) }
}

/// Textvorlage für das Einsatztagebuch.
public struct TextTemplate: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var text: String
    /// Wie oft die Vorlage benutzt wurde (für die Sortierung, wie ELRDRG).
    public var useCount: Int

    public init(id: UUID = UUID(), text: String, useCount: Int = 0) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.useCount = max(useCount, 0)
    }
}

/// Vergleichsregeln zum Erkennen doppelter Stammdaten.
public enum MasterDataMatching {
    /// Kleinbuchstaben, Leerraum zusammengefasst, ohne führende/folgende Leerzeichen.
    public static func key(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
