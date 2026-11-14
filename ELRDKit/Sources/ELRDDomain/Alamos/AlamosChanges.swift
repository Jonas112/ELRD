import Foundation

/// Was aus einem FE2-Einsatz zuletzt in den ELRD-Einsatz übernommen wurde (Schritt 143).
///
/// Bewusst ohne Patientennamen: Patienten werden nur über die Patientennummer der
/// Leitstelle bzw. ihre Position erkannt, Fahrzeuge über den Funkrufnamen.
public struct AlarmSnapshot: Codable, Hashable, Sendable {
    public var keyword: String?
    public var keywordDescription: String?
    public var address: String?
    /// Alarmtext-Zeilen (getrimmt, ohne leere).
    public var message: [String]
    /// Funkrufnamen als Vergleichsschlüssel (`MasterDataMatching.key`).
    public var vehicleKeys: [String]
    /// Patientennummer der Leitstelle, sonst „#1“, „#2“ … (Position unter denen ohne Nummer).
    public var patientKeys: [String]

    public init(
        keyword: String? = nil,
        keywordDescription: String? = nil,
        address: String? = nil,
        message: [String] = [],
        vehicleKeys: [String] = [],
        patientKeys: [String] = []
    ) {
        self.keyword = keyword
        self.keywordDescription = keywordDescription
        self.address = address
        self.message = message
        self.vehicleKeys = vehicleKeys
        self.patientKeys = patientKeys
    }

    public init(_ data: AlamosAlarmData) {
        self.init(
            keyword: data.keyword,
            keywordDescription: data.keywordDescription,
            address: data.location?.addressLine.trimmed,
            message: data.messageLines,
            vehicleKeys: data.callsigns.map(MasterDataMatching.key),
            patientKeys: data.patientKeys
        )
    }
}

/// Unterschiede eines neuen FE2-Stands gegenüber einem früheren (Schritt 143).
public struct AlamosChanges: Hashable, Sendable {
    /// „RD 3 → RD 4 – VU Reisebus“, falls sich Stichwort oder Beschreibung geändert haben.
    public var keyword: String?
    /// Neue Adresse, falls sie sich geändert hat.
    public var address: String?
    /// Neu hinzugekommene Zeilen im Alarmtext.
    public var messageLines: [String]
    /// Neu alarmierte Fahrzeuge (Funkrufnamen, wie FE2 sie liefert).
    public var callsigns: [String]
    /// Neu gemeldete Patienten.
    public var patients: [AlamosPatient]

    public init(keyword: String? = nil, address: String? = nil, messageLines: [String] = [], callsigns: [String] = [], patients: [AlamosPatient] = []) {
        self.keyword = keyword
        self.address = address
        self.messageLines = messageLines
        self.callsigns = callsigns
        self.patients = patients
    }

    public var isEmpty: Bool {
        keyword == nil && address == nil && messageLines.isEmpty && callsigns.isEmpty && patients.isEmpty
    }

    /// Kurzfassung für Hinweis und Mitteilung – ohne Patientennamen (Sperrbildschirm).
    public var summary: [String] {
        var lines: [String] = []
        if let keyword { lines.append("Stichwort \(keyword)") }
        if !callsigns.isEmpty {
            lines.append("+\(callsigns.count) \(callsigns.count == 1 ? "Fahrzeug" : "Fahrzeuge"): \(callsigns.joined(separator: ", "))")
        }
        if !patients.isEmpty { lines.append("+\(patients.count) \(patients.count == 1 ? "Patient" : "Patienten")") }
        if !messageLines.isEmpty { lines.append("Alarmtext ergänzt") }
        if let address { lines.append("Einsatzort: \(address)") }
        return lines
    }
}

public extension AlamosAlarmData {
    /// Alarmtext-Zeilen, getrimmt und ohne leere.
    var messageLines: [String] {
        message.compactMap(\.trimmed)
    }

    /// Schlüssel je gemeldetem Patienten (siehe `AlarmSnapshot.patientKeys`).
    var patientKeys: [String] {
        var withoutNumber = 0
        return patients.map { patient in
            if let number = patient.patientNumber?.trimmed { return number }
            withoutNumber += 1
            return "#\(withoutNumber)"
        }
    }

    /// Unterschiede zu einem früheren Stand. Weggefallenes (Fahrzeug abbestellt, Zeile
    /// gelöscht) zählt nicht: übernommen wird nur, was neu dazukommt.
    func changes(since old: AlarmSnapshot) -> AlamosChanges {
        var changes = AlamosChanges()
        let newSnapshot = AlarmSnapshot(self)
        if newSnapshot.keyword != old.keyword || newSnapshot.keywordDescription != old.keywordDescription {
            let before = old.keyword ?? old.keywordDescription ?? "–"
            let after = [keyword, keywordDescription].compactMap { $0?.trimmed }.joined(separator: " – ")
            changes.keyword = "\(before) → \(after.isEmpty ? "–" : after)"
        }
        if let address = newSnapshot.address, address != old.address {
            changes.address = address
        }
        let oldLines = Set(old.message)
        changes.messageLines = newSnapshot.message.filter { !oldLines.contains($0) }
        let oldVehicles = Set(old.vehicleKeys)
        changes.callsigns = callsigns.filter { !oldVehicles.contains(MasterDataMatching.key($0)) }
        let oldPatients = Set(old.patientKeys)
        changes.patients = zip(patients, patientKeys).filter { !oldPatients.contains($0.1) }.map(\.0)
        return changes
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
