import Foundation
import ELRDDomain

/// Hinweis zu einer Zeile, die nicht übernommen werden konnte.
public struct ImportIssue: Hashable, Sendable, CustomStringConvertible {
    public let line: Int
    public let message: String

    public var description: String { "Zeile \(line): \(message)" }
}

/// Ergebnis eines Datei-Imports. Gültige Zeilen werden übernommen, ungültige
/// gemeldet (Teilerfolg statt Abbruch wegen einer fehlerhaften Zeile).
public struct ImportResult<Item: Sendable>: Sendable {
    public var items: [Item] = []
    public var issues: [ImportIssue] = []
}

/// Liest Fahrzeug-, Klinik- und Diagnoselisten aus CSV.
///
/// Spalten werden über die Überschrift erkannt (Reihenfolge egal). Fehlt eine
/// Überschrift, gilt die Standardreihenfolge der ELRDRG-Listen.
public enum MasterDataImporter {
    // MARK: Fahrzeuge

    /// Erwartet „Funkrufname;Typ“ (Typspalte auch „Einsatzmitteltyp“ o. ä.).
    public static func units(fromCSV text: String, origin: MasterDataOrigin) -> ImportResult<MasterUnit> {
        let rows = CSVParser.parse(text)
        let columns = ColumnMap(
            rows: rows,
            columns: [
                "callsign": ["funkrufname", "rufname", "callsign", "name"],
                "type": ["typ", "einsatzmitteltyp", "emtypen typ name", "fahrzeugtyp", "type"],
                "crew": ["besatzung", "stärke", "staerke", "crew"],
            ],
            defaultOrder: ["callsign", "type", "crew"]
        )
        var result = ImportResult<MasterUnit>()
        for row in columns.dataRows {
            let callsign = columns.value("callsign", in: row) ?? ""
            guard !callsign.isEmpty else {
                result.issues.append(ImportIssue(line: row.line, message: "Funkrufname fehlt"))
                continue
            }
            let label = columns.value("type", in: row) ?? ""
            let crew = columns.value("crew", in: row).flatMap { Int($0) }
            result.items.append(MasterUnit(
                callsign: callsign,
                type: UnitTypeMapping.unitType(for: label),
                typeLabel: label,
                crewCount: crew,
                origin: origin
            ))
        }
        return result
    }

    // MARK: Kliniken

    /// Erwartet u. a. „Anzeigename;Straße + Hausnummer;Stadt;Latitude;Longitude;Telefonnummer;E-Mail Adresse“.
    public static func hospitals(fromCSV text: String, origin: MasterDataOrigin) -> ImportResult<MasterHospital> {
        let rows = CSVParser.parse(text)
        let columns = ColumnMap(
            rows: rows,
            columns: [
                "name": ["anzeigename", "name", "klinik"],
                "address": ["straße + hausnummer", "strasse + hausnummer", "straße", "strasse", "adresse"],
                "city": ["stadt", "ort", "plz ort"],
                "lat": ["latitude", "breitengrad", "lat"],
                "lng": ["longitude", "längengrad", "laengengrad", "lng", "lon"],
                "phone": ["telefonnummer", "telefon"],
                "email": ["e-mail adresse", "e-mail", "email"],
                "registration": ["e-mail adresse anmeldung", "anmeldung"],
            ],
            defaultOrder: ["name", "address", "city", "lat", "lng", "phone", "email", "registration"]
        )
        var result = ImportResult<MasterHospital>()
        for row in columns.dataRows {
            let name = columns.value("name", in: row) ?? ""
            guard !name.isEmpty else {
                result.issues.append(ImportIssue(line: row.line, message: "Klinikname fehlt"))
                continue
            }
            let latitudeText = columns.value("lat", in: row)
            let longitudeText = columns.value("lng", in: row)
            let latitude = latitudeText.flatMap(parseDecimal)
            let longitude = longitudeText.flatMap(parseDecimal)
            if (latitudeText != nil && latitude == nil) || (longitudeText != nil && longitude == nil) {
                result.issues.append(ImportIssue(line: row.line, message: "Koordinaten bei „\(name)“ nicht lesbar – ohne Position übernommen"))
            }
            var coordinate: GeoCoordinate?
            if let latitude, let longitude {
                coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
                if coordinate == nil {
                    result.issues.append(ImportIssue(line: row.line, message: "Ungültige Koordinaten bei „\(name)“ – ohne Position übernommen"))
                }
            }
            result.items.append(MasterHospital(
                name: name,
                address: columns.value("address", in: row) ?? "",
                city: columns.value("city", in: row) ?? "",
                phone: columns.value("phone", in: row) ?? "",
                email: columns.value("email", in: row) ?? "",
                registrationEmail: columns.value("registration", in: row),
                coordinate: coordinate,
                origin: origin
            ))
        }
        return result
    }

    // MARK: Diagnosen

    /// Erwartet „Körperregion;Diagnose“; die Region darf leer sein.
    public static func injuries(fromCSV text: String, origin: MasterDataOrigin) -> ImportResult<MasterInjury> {
        let rows = CSVParser.parse(text)
        let columns = ColumnMap(
            rows: rows,
            columns: [
                "region": ["körperregion", "koerperregion", "region", "lokalisation"],
                "diagnosis": ["diagnose", "verletzung", "diagnosis"],
            ],
            defaultOrder: ["region", "diagnosis"]
        )
        var result = ImportResult<MasterInjury>()
        for row in columns.dataRows {
            let diagnosis = columns.value("diagnosis", in: row) ?? ""
            guard !diagnosis.isEmpty else {
                result.issues.append(ImportIssue(line: row.line, message: "Diagnose fehlt"))
                continue
            }
            let regionText = columns.value("region", in: row) ?? ""
            let region = BodyRegion(legacyText: regionText)
            if region == nil && !regionText.isEmpty {
                result.issues.append(ImportIssue(line: row.line, message: "Unbekannte Körperregion „\(regionText)“ – ohne Region übernommen"))
            }
            result.items.append(MasterInjury(diagnosis: diagnosis, region: region, origin: origin))
        }
        return result
    }

    /// Dezimalzahl mit Punkt oder Komma.
    static func parseDecimal(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }
}

/// Zuordnung Spaltenname → Index anhand der Überschrift.
struct ColumnMap {
    let indices: [String: Int]
    let dataRows: [CSVParser.Row]

    init(rows: [CSVParser.Row], columns: [String: [String]], defaultOrder: [String]) {
        guard let header = rows.first else {
            indices = [:]
            dataRows = []
            return
        }
        let normalizedHeader = header.fields.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        var found: [String: Int] = [:]
        for (key, aliases) in columns {
            // Genaueste Übereinstimmung zuerst: exakter Name, dann Teilstring.
            if let index = normalizedHeader.firstIndex(where: { aliases.contains($0) }) {
                found[key] = index
            }
        }
        if found.isEmpty {
            // Keine Überschrift (z. B. Fahrzeuge-Coburg): Standardreihenfolge, erste Zeile ist Datenzeile.
            indices = Dictionary(uniqueKeysWithValues: defaultOrder.enumerated().map { ($1, $0) })
            dataRows = rows
        } else {
            indices = found
            dataRows = Array(rows.dropFirst())
        }
    }

    func value(_ key: String, in row: CSVParser.Row) -> String? {
        guard let index = indices[key], let value = row[index], !value.isEmpty else { return nil }
        return value
    }
}
