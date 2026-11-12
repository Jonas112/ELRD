import Foundation
import ELRDDomain

/// Übernahme eines Einsatzes aus Alamos FE2 in einen neuen ELRD-Einsatz (Schritt 140).
///
/// Läuft im selben Speichervorgang wie das Anlegen (`NewMissionRequest.alarmImport`):
/// Einsatzort auf der Karte, Bezug auf die FE2-Einsatznummer, Tagebucheintrag mit dem
/// Alarmtext, alarmierte Fahrzeuge (aus den Stammdaten, sonst temporär) und die von
/// der Leitstelle gemeldeten Patienten (ungesichtet, Bemerkung als Notiz).
public struct AlarmImport: Sendable {
    public var alarm: AlamosAlarm
    /// Alarmierte Fahrzeuge in den Einsatz übernehmen.
    public var includesVehicles: Bool
    /// Gemeldete Patienten anlegen.
    public var includesPatients: Bool
    /// Fahrzeuge der Stammdaten zum Zuordnen nach Funkrufname.
    public var masterUnits: [MasterUnit]

    public init(alarm: AlamosAlarm, includesVehicles: Bool = true, includesPatients: Bool = true, masterUnits: [MasterUnit] = []) {
        self.alarm = alarm
        self.includesVehicles = includesVehicles
        self.includesPatients = includesPatients
        self.masterUnits = masterUnits
    }

    /// Fahrzeug aus FE2 mit Treffer in den Stammdaten (oder ohne).
    public struct VehicleMatch: Hashable, Sendable {
        public let callsign: String
        public let master: MasterUnit?
        public let type: UnitType
    }

    /// Zuordnung der alarmierten Fahrzeuge (für Vorschau und Übernahme).
    public var vehicleMatches: [VehicleMatch] {
        let byKey = Dictionary(masterUnits.map { (MasterDataMatching.key($0.callsign), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return alarm.data.vehicles.compactMap { vehicle in
            guard let callsign = vehicle.callsign else { return nil }
            let key = MasterDataMatching.key(callsign)
            guard seen.insert(key).inserted else { return nil }
            let master = byKey[key]
            return VehicleMatch(callsign: master?.callsign ?? callsign, master: master, type: master?.type ?? vehicle.guessedUnitType)
        }
    }

    @MainActor
    func apply(to draft: inout MissionDraft) throws {
        let data = alarm.data
        let reference = ExternalAlarmReference(externalID: alarm.externalId, revision: alarm.revision, importedAt: draft.context.now)
        let coordinate = data.location?.geoCoordinate
        try draft.updateMission {
            $0.externalAlarm = reference
            if $0.coordinate == nil, let coordinate { $0.coordinate = coordinate }
        }
        _ = try draft.addJournalEntry(text: data.journalText, origin: .automatic)
        draft.log(.mission, "Aus Alamos FE2 übernommen (Einsatznummer \(alarm.externalId), Stand \(alarm.revision))", subject: .mission(draft.missionID))

        if includesVehicles {
            let matches = vehicleMatches
            let masters = matches.compactMap(\.master)
            if !masters.isEmpty { _ = try AddMasterUnits(masters).execute(&draft) }
            for match in matches where match.master == nil {
                // Doppelte (gleicher Funkrufname schon im Einsatz) still überspringen.
                _ = try? AddTemporaryUnit(callsign: match.callsign, type: match.type).execute(&draft)
            }
        }

        if includesPatients {
            for reported in data.patients {
                let patient = try AddPatient(triage: .ungesichtet).execute(&draft)
                let (first, last) = Self.splitName(reported.name)
                let notes = Self.notes(for: reported)
                try draft.update(Patient.self, id: patient.id) {
                    $0.dispatchPatientNumber = reported.patientNumber
                    if let first { $0.firstName = first }
                    if let last { $0.lastName = last }
                    if !notes.isEmpty { $0.notes = notes }
                }
            }
        }
    }

    /// „Max Mustermann“ → („Max“, „Mustermann“); „Mustermann, Max“ → („Max“, „Mustermann“).
    static func splitName(_ name: String?) -> (first: String?, last: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return (nil, nil) }
        if let comma = name.firstIndex(of: ",") {
            let last = name[..<comma].trimmingCharacters(in: .whitespaces)
            let first = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return (first.isEmpty ? nil : first, last.isEmpty ? nil : last)
        }
        var parts = name.split(whereSeparator: \.isWhitespace).map(String.init)
        let last = parts.removeLast()
        return (parts.isEmpty ? nil : parts.joined(separator: " "), last)
    }

    static func notes(for patient: AlamosPatient) -> String {
        var lines: [String] = []
        if let remark = patient.remark { lines.append("Leitstelle: \(remark)") }
        if let destination = patient.destination { lines.append("Ziel lt. Leitstelle: \(destination)") }
        return lines.joined(separator: "\n")
    }
}
