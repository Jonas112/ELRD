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
    /// Schlüssel der neuen Patienten (gleiche Reihenfolge wie `patients`).
    public var patientKeys: [String]

    public init(
        keyword: String? = nil,
        address: String? = nil,
        messageLines: [String] = [],
        callsigns: [String] = [],
        patients: [AlamosPatient] = [],
        patientKeys: [String]? = nil
    ) {
        self.keyword = keyword
        self.address = address
        self.messageLines = messageLines
        self.callsigns = callsigns
        self.patients = patients
        self.patientKeys = patientKeys ?? patients.indices.map { "#\($0 + 1)" }
    }

    public var isEmpty: Bool {
        keyword == nil && address == nil && messageLines.isEmpty && callsigns.isEmpty && patients.isEmpty
    }

    /// Eine Meldung je Art der Änderung (Schritt 143) – ohne Patientennamen (Sperrbildschirm).
    public struct Entry: Hashable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Sendable {
            case keyword, vehicles, patients, message, address
        }

        public let kind: Kind
        public let text: String
        public var id: Kind { kind }

        /// SF-Symbol für die Anzeige.
        public var systemImage: String {
            switch kind {
            case .keyword: "exclamationmark.bubble"
            case .vehicles: "car.2"
            case .patients: "person.2"
            case .message: "text.bubble"
            case .address: "mappin.and.ellipse"
            }
        }
    }

    public var entries: [Entry] {
        var entries: [Entry] = []
        if let keyword { entries.append(Entry(kind: .keyword, text: "Stichwort \(keyword)")) }
        if !callsigns.isEmpty {
            let noun = callsigns.count == 1 ? "Fahrzeug" : "Fahrzeuge"
            entries.append(Entry(kind: .vehicles, text: "+\(callsigns.count) \(noun) nachalarmiert: \(callsigns.joined(separator: ", "))"))
        }
        if !patients.isEmpty {
            entries.append(Entry(kind: .patients, text: "+\(patients.count) \(patients.count == 1 ? "Patient" : "Patienten") gemeldet"))
        }
        if !messageLines.isEmpty {
            entries.append(Entry(kind: .message, text: "Alarmtext ergänzt (\(messageLines.count) \(messageLines.count == 1 ? "Zeile" : "Zeilen"))"))
        }
        if let address { entries.append(Entry(kind: .address, text: "Einsatzort: \(address)")) }
        return entries
    }

    /// Kurzfassung (je Meldung eine Zeile).
    public var summary: [String] { entries.map(\.text) }
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
        let added = zip(patients, patientKeys).filter { !oldPatients.contains($0.1) }
        changes.patients = added.map { $0.0 }
        changes.patientKeys = added.map { $0.1 }
        return changes
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
