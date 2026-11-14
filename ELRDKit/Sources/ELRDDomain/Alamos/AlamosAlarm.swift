import Foundation

/// Einsatz aus Alamos FE2, wie ihn das ELRD-Backend (Datenschublade) liefert.
///
/// `data` ist das unveränderte `data`-Objekt im Datenformat V2 der externen
/// Schnittstelle von FE2 (so erzeugt es das JSON-Plugin). Gelesen wird großzügig:
/// fehlende oder unerwartete Felder führen nie zum Fehler, sondern zu `nil`/leer.
public struct AlamosAlarm: Codable, Hashable, Sendable, Identifiable {
    /// Kennung im Backend.
    public let id: UUID
    /// Einsatznummer aus FE2 (`data.externalId`); Aktualisierungen tragen dieselbe Nummer.
    public let externalId: String
    /// Stand: 1 = erste Meldung, jede inhaltliche Änderung zählt hoch.
    public let revision: Int
    public let receivedAt: Date
    public let updatedAt: Date
    /// In FE2 geschlossen (`CLOSE`).
    public let closedAt: Date?
    public let sender: String?
    /// Von der Debug-Seite oder dem Testskript angelegt.
    public let isTest: Bool
    public let data: AlamosAlarmData

    public init(
        id: UUID = UUID(),
        externalId: String,
        revision: Int = 1,
        receivedAt: Date,
        updatedAt: Date? = nil,
        closedAt: Date? = nil,
        sender: String? = nil,
        isTest: Bool = false,
        data: AlamosAlarmData
    ) {
        self.id = id
        self.externalId = externalId
        self.revision = revision
        self.receivedAt = receivedAt
        self.updatedAt = updatedAt ?? receivedAt
        self.closedAt = closedAt
        self.sender = sender
        self.isTest = isTest
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        externalId = try container.decodeLenientString(forKey: .externalId) ?? ""
        revision = (try? container.decodeIfPresent(Int.self, forKey: .revision)) ?? 1
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? receivedAt
        closedAt = try? container.decodeIfPresent(Date.self, forKey: .closedAt)
        sender = try container.decodeLenientString(forKey: .sender)
        isTest = (try? container.decodeIfPresent(Bool.self, forKey: .isTest)) ?? false
        data = (try? container.decodeIfPresent(AlamosAlarmData.self, forKey: .data)) ?? AlamosAlarmData()
    }

    public var isClosed: Bool { closedAt != nil }
}

/// `data` im Datenformat V2 der externen Schnittstelle von FE2.
public struct AlamosAlarmData: Codable, Hashable, Sendable {
    public var externalId: String?
    public var keyword: String?
    public var keywordDescription: String?
    public var keywordMisc: String?
    /// Alarmtext, je Zeile ein Eintrag.
    public var message: [String]
    public var location: AlamosLocation?
    public var caller: AlamosCaller?
    public var patients: [AlamosPatient]
    public var vehicles: [AlamosVehicle]
    /// Zusätzliche Parameter aus FE2 (`custom`), Werte als Text.
    public var custom: [String: String]

    public init(
        externalId: String? = nil,
        keyword: String? = nil,
        keywordDescription: String? = nil,
        keywordMisc: String? = nil,
        message: [String] = [],
        location: AlamosLocation? = nil,
        caller: AlamosCaller? = nil,
        patients: [AlamosPatient] = [],
        vehicles: [AlamosVehicle] = [],
        custom: [String: String] = [:]
    ) {
        self.externalId = externalId
        self.keyword = keyword
        self.keywordDescription = keywordDescription
        self.keywordMisc = keywordMisc
        self.message = message
        self.location = location
        self.caller = caller
        self.patients = patients
        self.vehicles = vehicles
        self.custom = custom
    }

    enum CodingKeys: String, CodingKey {
        case externalId
        case keyword
        case keywordDescription = "keyword_description"
        case keywordMisc = "keyword_misc"
        case message, location, caller
        case patients = "patient"
        case vehicles, custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        externalId = try container.decodeLenientString(forKey: .externalId)
        keyword = try container.decodeLenientString(forKey: .keyword)
        keywordDescription = try container.decodeLenientString(forKey: .keywordDescription)
        keywordMisc = try container.decodeLenientString(forKey: .keywordMisc)
        // Alarmtext: Liste von Zeilen, manche Quellen schicken einen Text.
        if let lines = try? container.decodeIfPresent([String].self, forKey: .message) {
            message = lines
        } else if let text = try container.decodeLenientString(forKey: .message) {
            message = text.components(separatedBy: .newlines)
        } else {
            message = []
        }
        location = try? container.decodeIfPresent(AlamosLocation.self, forKey: .location)
        caller = try? container.decodeIfPresent(AlamosCaller.self, forKey: .caller)
        patients = (try? container.decodeIfPresent(LenientArray<AlamosPatient>.self, forKey: .patients))?.elements ?? []
        vehicles = (try? container.decodeIfPresent(LenientArray<AlamosVehicle>.self, forKey: .vehicles))?.elements ?? []
        custom = (try? container.decodeIfPresent(LenientStringMap.self, forKey: .custom))?.values ?? [:]
    }
}

public struct AlamosLocation: Codable, Hashable, Sendable {
    /// Laut Alamos: erste Stelle Längengrad (X), zweite Breitengrad (Y).
    public var coordinate: [Double]?
    public var building: String?
    public var street: String?
    public var house: String?
    public var crossing: String?
    public var additional: String?
    public var postalCode: String?
    public var city: String?
    public var cityAbbreviation: String?

    public init(
        coordinate: [Double]? = nil,
        building: String? = nil,
        street: String? = nil,
        house: String? = nil,
        crossing: String? = nil,
        additional: String? = nil,
        postalCode: String? = nil,
        city: String? = nil,
        cityAbbreviation: String? = nil
    ) {
        self.coordinate = coordinate
        self.building = building
        self.street = street
        self.house = house
        self.crossing = crossing
        self.additional = additional
        self.postalCode = postalCode
        self.city = city
        self.cityAbbreviation = cityAbbreviation
    }

    enum CodingKeys: String, CodingKey {
        case coordinate, building, street, house, crossing, additional, postalCode, city
        case cityAbbreviation = "city_abbr"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coordinate = try? container.decodeIfPresent([Double].self, forKey: .coordinate)
        building = try container.decodeLenientString(forKey: .building)
        street = try container.decodeLenientString(forKey: .street)
        house = try container.decodeLenientString(forKey: .house)
        crossing = try container.decodeLenientString(forKey: .crossing)
        additional = try container.decodeLenientString(forKey: .additional)
        postalCode = try container.decodeLenientString(forKey: .postalCode)
        city = try container.decodeLenientString(forKey: .city)
        cityAbbreviation = try container.decodeLenientString(forKey: .cityAbbreviation)
    }

    /// Koordinate in ELRD-Reihenfolge; `nil` ohne gültige Werte (oder 0/0).
    public var geoCoordinate: GeoCoordinate? {
        guard let coordinate, coordinate.count >= 2, !(coordinate[0] == 0 && coordinate[1] == 0) else { return nil }
        return GeoCoordinate(latitude: coordinate[1], longitude: coordinate[0])
    }

    /// „Niederwerrner Straße 100, 97421 Schweinfurt“ (+ Objekt, Kreuzung, Zusatz).
    public var addressLine: String {
        let streetPart = [street, house].compactMap(\.nonEmpty).joined(separator: " ")
        let cityPart = [postalCode, city].compactMap(\.nonEmpty).joined(separator: " ")
        var parts = [building, streetPart.nonEmpty, crossing.nonEmpty.map { "Kreuzung \($0)" }, cityPart.nonEmpty]
            .compactMap(\.nonEmpty)
        if let additional = additional.nonEmpty { parts.append(additional) }
        return parts.joined(separator: ", ")
    }
}

public struct AlamosCaller: Codable, Hashable, Sendable {
    public var name: String?
    public var contact: String?

    public init(name: String? = nil, contact: String? = nil) {
        self.name = name
        self.contact = contact
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeLenientString(forKey: .name)
        contact = try container.decodeLenientString(forKey: .contact)
    }
}

public struct AlamosPatient: Codable, Hashable, Sendable {
    public var name: String?
    /// Bemerkung der Leitstelle (Verletzungen, Zustand).
    public var remark: String?
    /// Transportziel.
    public var destination: String?
    /// Patientennummer der Leitstelle.
    public var patientNumber: String?

    public init(name: String? = nil, remark: String? = nil, destination: String? = nil, patientNumber: String? = nil) {
        self.name = name
        self.remark = remark
        self.destination = destination
        self.patientNumber = patientNumber
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeLenientString(forKey: .name)
        remark = try container.decodeLenientString(forKey: .remark)
        destination = try container.decodeLenientString(forKey: .destination)
        patientNumber = try container.decodeLenientString(forKey: .patientNumber)
    }
}

public struct AlamosVehicle: Codable, Hashable, Sendable {
    public var id: String?
    public var unitType: String?
    public var name: String?
    public var radioName: String?
    public var station: String?
    /// Alarmierungszeit in Millisekunden seit 1970.
    public var alarmedTime: Double?
    public var dispoInfo: String?
    public var jobNumber: String?
    public var patientNumber: String?

    public init(
        id: String? = nil,
        unitType: String? = nil,
        name: String? = nil,
        radioName: String? = nil,
        station: String? = nil,
        alarmedTime: Double? = nil,
        dispoInfo: String? = nil,
        jobNumber: String? = nil,
        patientNumber: String? = nil
    ) {
        self.id = id
        self.unitType = unitType
        self.name = name
        self.radioName = radioName
        self.station = station
        self.alarmedTime = alarmedTime
        self.dispoInfo = dispoInfo
        self.jobNumber = jobNumber
        self.patientNumber = patientNumber
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        unitType = try container.decodeLenientString(forKey: .unitType)
        name = try container.decodeLenientString(forKey: .name)
        radioName = try container.decodeLenientString(forKey: .radioName)
        station = try container.decodeLenientString(forKey: .station)
        if let number = try? container.decodeIfPresent(Double.self, forKey: .alarmedTime) {
            alarmedTime = number
        } else {
            alarmedTime = try container.decodeLenientString(forKey: .alarmedTime).flatMap(Double.init)
        }
        dispoInfo = try container.decodeLenientString(forKey: .dispoInfo)
        jobNumber = try container.decodeLenientString(forKey: .jobNumber)
        patientNumber = try container.decodeLenientString(forKey: .patientNumber)
    }

    /// Funkrufname, sonst Name.
    public var callsign: String? { radioName.nonEmpty ?? name.nonEmpty }

    public var alarmedAt: Date? {
        alarmedTime.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

// MARK: - Fachlogik

public extension AlamosAlarmData {
    /// Titel: Beschreibung des Stichworts, sonst Stichwort, sonst erste Textzeile.
    var title: String {
        keywordDescription.nonEmpty ?? keyword.nonEmpty ?? message.first.nonEmpty ?? "Einsatz ohne Stichwort"
    }

    /// RD-Stichwort, falls es einem bekannten ELRD-Stichwort entspricht („RD2“ → RD 2).
    var alarmstichwort: Alarmstichwort? {
        guard let keyword = keyword.nonEmpty else { return nil }
        let compact = keyword.uppercased().filter { !$0.isWhitespace }
        return Alarmstichwort.allCases.first { $0.rawValue.uppercased().filter { !$0.isWhitespace } == compact }
    }

    /// Fahrzeuge mit Funkrufnamen, ohne Doppelte (Groß-/Kleinschreibung egal).
    var callsigns: [String] {
        var seen = Set<String>()
        return vehicles.compactMap(\.callsign).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Text für das Einsatztagebuch beim Übernehmen.
    var journalText: String {
        var lines = ["Einsatz aus Alamos FE2 übernommen."]
        if let externalId = externalId.nonEmpty { lines.append("Einsatznummer: \(externalId)") }
        let keywordLine = [keyword.nonEmpty, keywordDescription.nonEmpty, keywordMisc.nonEmpty].compactMap { $0 }.joined(separator: " – ")
        if !keywordLine.isEmpty { lines.append("Stichwort: \(keywordLine)") }
        if let address = location?.addressLine.nonEmpty { lines.append("Einsatzort: \(address)") }
        let text = message.compactMap(\.nonEmpty)
        if !text.isEmpty { lines.append("Alarmtext:\n" + text.joined(separator: "\n")) }
        if !callsigns.isEmpty { lines.append("Alarmierte Fahrzeuge: " + callsigns.joined(separator: ", ")) }
        if !patients.isEmpty { lines.append("Gemeldete Patienten: \(patients.count)") }
        return lines.joined(separator: "\n")
    }
}

public extension AlamosVehicle {
    /// Einheitentyp aus `unitType` bzw. dem Funkrufnamen (bayerische Kenner 71/72/76/…).
    var guessedUnitType: UnitType {
        let label = (unitType ?? "").uppercased()
        let table: [(String, UnitType)] = [
            ("KTW-KATS", .ktwKatS), ("NEF", .nef), ("NAW", .rtw), ("RTW", .rtw), ("ITW", .rtw), ("KTW", .ktw),
            ("RTH", .rth), ("ITH", .rth), ("CHRISTOPH", .rth), ("KDOW", .kdow), ("ELW", .elw), ("MTW", .mtw), ("LKW", .lkw),
        ]
        if let match = table.first(where: { label.contains($0.0) }) { return match.1 }
        let name = (callsign ?? "").uppercased()
        if name.contains("CHRISTOPH") { return .rth }
        if let range = name.range(of: #"\b(\d{2})/\d+"#, options: .regularExpression) {
            switch name[range].prefix(2) {
            case "71", "73", "79": return .rtw
            case "72": return .ktw
            case "76", "82": return .nef
            case "10", "11", "12": return .kdow
            default: break
            }
        }
        return .sonstiges
    }
}

/// Bezug eines ELRD-Einsatzes auf einen Einsatz im Alarmierungssystem (Schritt 140).
public struct ExternalAlarmReference: Codable, Hashable, Sendable {
    /// Herkunft, z. B. „Alamos FE2“.
    public var source: String
    /// Einsatznummer im Alarmierungssystem (`externalId`).
    public var externalID: String
    /// Übernommener Stand.
    public var revision: Int
    public var importedAt: Date
    /// Schritt 143: Inhalt des übernommenen Stands (für den Vergleich mit neuen Ständen).
    /// Fehlt bei Einsätzen, die vor Schritt 143 übernommen wurden.
    public var applied: AlarmSnapshot?
    /// Schritt 143: Hinweis auf diesen Stand ausgeblendet, ohne zu übernehmen.
    public var dismissedRevision: Int?

    public init(
        source: String = ExternalAlarmReference.alamosSource,
        externalID: String,
        revision: Int,
        importedAt: Date,
        applied: AlarmSnapshot? = nil,
        dismissedRevision: Int? = nil
    ) {
        self.source = source
        self.externalID = externalID
        self.revision = revision
        self.importedAt = importedAt
        self.applied = applied
        self.dismissedRevision = dismissedRevision
    }

    public static let alamosSource = "Alamos FE2"
}

// MARK: - Großzügiges Lesen

private extension KeyedDecodingContainer {
    /// Text, Zahl oder Wahrheitswert als Text; leer → `nil`; falscher Typ → `nil`.
    func decodeLenientString(forKey key: Key) throws -> String? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        if let text = try? decode(String.self, forKey: key) { return text.nonEmpty }
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        if let number = try? decode(Double.self, forKey: key) { return String(number) }
        if let flag = try? decode(Bool.self, forKey: key) { return flag ? "true" : "false" }
        return nil
    }
}

/// Liste, in der unlesbare Elemente übersprungen werden.
private struct LenientArray<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                break // sollte nie passieren – sonst Endlosschleife
            }
        }
    }

    /// Überspringt ein Element; liest nichts und gelingt immer, damit der Container weiterrückt.
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

/// Objekt mit beliebigen Werten → Text.
private struct LenientStringMap: Decodable {
    var values: [String: String] = [:]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys {
            if let text = try container.decodeLenientString(forKey: key) { values[key.stringValue] = text }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var nonEmpty: String? { Optional(self).nonEmpty }
}

// MARK: - Antwort des Backends

/// Antwort auf `GET /api/v1/alarms`.
public struct AlamosAlarmList: Codable, Sendable {
    public let serverTime: Date
    public let alarms: [AlamosAlarm]

    public init(serverTime: Date, alarms: [AlamosAlarm]) {
        self.serverTime = serverTime
        self.alarms = alarms
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverTime = try container.decode(Date.self, forKey: .serverTime)
        alarms = (try container.decodeIfPresent(LenientArray<AlamosAlarm>.self, forKey: .alarms))?.elements ?? []
    }
}

/// Antwort auf `GET /api/v1/ping`.
public struct AlamosPing: Codable, Hashable, Sendable {
    public let organisationId: String
    public let organisationName: String
    public let serverTime: Date
    public let version: String
    public let retentionHours: Int?
    /// Schritt 144: Backend kann Push-Mitteilungen senden (fehlt bei älteren Backends).
    public let pushEnabled: Bool?
}

/// Antwort auf `POST /api/v1/devices` (Schritt 144).
public struct AlamosDeviceRegistration: Codable, Hashable, Sendable {
    public let registered: Bool
    public let pushEnabled: Bool

    public init(registered: Bool, pushEnabled: Bool) {
        self.registered = registered
        self.pushEnabled = pushEnabled
    }
}

public enum AlamosJSON {
    /// Decoder für Antworten des Backends (Zeitpunkte ISO 8601, mit oder ohne Bruchteile).
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Zeitpunkt „\(text)“ unlesbar")
        }
        return decoder
    }

    public static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Zeitpunkt für `since` (UTC, Millisekunden).
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
