import Foundation

/// Zielklinik eines Patienten als Momentaufnahme.
///
/// Die Werte werden beim Auswählen aus den Stammdaten kopiert. Spätere Änderungen
/// an den Stammdaten verändern so keine abgeschlossenen Einsätze und Berichte.
public struct HospitalSnapshot: Hashable, Codable, Sendable {
    public var name: String
    public var address: String
    public var city: String
    public var phone: String
    public var email: String
    public var coordinate: GeoCoordinate?
    public var masterHospitalID: MasterHospitalID?

    public init(
        name: String,
        address: String = "",
        city: String = "",
        phone: String = "",
        email: String = "",
        coordinate: GeoCoordinate? = nil,
        masterHospitalID: MasterHospitalID? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address
        self.city = city
        self.phone = phone
        self.email = email
        self.coordinate = coordinate
        self.masterHospitalID = masterHospitalID
    }

    /// Anzeige wie in ELRDRG: „Name / Ort“ (ohne Ort nur der Name).
    public var displayName: String {
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCity.isEmpty ? name : "\(name) / \(trimmedCity)"
    }
}
