import Foundation
import ELRDDomain

/// Neuer Stand eines übernommenen FE2-Einsatzes gegenüber dem ELRD-Einsatz (Schritt 143).
///
/// Grundlage ist der zuletzt übernommene Stand (`ExternalAlarmReference.applied`).
/// Übernommen wird nur, was neu ist; nichts im Einsatz wird überschrieben (E125, E129).
/// Stichwort und Einsatzort ändern sich im Einsatz nicht, sie landen im Tagebuch.
public struct AlarmUpdate: Hashable, Sendable {
    public let alarm: AlamosAlarm
    public let changes: AlamosChanges
    /// Neue Fahrzeuge, die noch nicht im Einsatz sind (mit Stammdaten-Treffer).
    public let vehicles: [AlarmImport.VehicleMatch]

    /// `nil`, wenn der Einsatz nicht zu diesem FE2-Einsatz gehört, der Stand schon
    /// übernommen oder ausgeblendet ist oder nichts Neues enthält.
    public init?(alarm: AlamosAlarm, mission: Mission, units: [MissionUnit], patients: [Patient], masterUnits: [MasterUnit] = []) {
        guard let reference = mission.externalAlarm, reference.externalID == alarm.externalId,
              alarm.revision > reference.revision, alarm.revision > (reference.dismissedRevision ?? 0) else { return nil }
        let activeUnits = units.filter { !$0.metadata.isDeleted }
        let baseline = reference.applied ?? Self.legacyBaseline(alarm: alarm, units: activeUnits, patients: patients.filter { !$0.metadata.isDeleted })
        let changes = alarm.data.changes(since: baseline)
        let inMission = Set(activeUnits.compactMap(\.matchKey))
        let byKey = Dictionary(masterUnits.map { ($0.matchKey, $0) }, uniquingKeysWith: { first, _ in first })
        let source = Dictionary(alarm.data.vehicles.compactMap { vehicle in vehicle.callsign.map { (MasterDataMatching.key($0), vehicle) } },
                                uniquingKeysWith: { first, _ in first })
        let vehicles = changes.callsigns.compactMap { callsign -> AlarmImport.VehicleMatch? in
            let key = MasterDataMatching.key(callsign)
            guard !inMission.contains(key) else { return nil }
            let master = byKey[key]
            let guessed = source[key]?.guessedUnitType ?? .sonstiges
            return AlarmImport.VehicleMatch(callsign: master?.callsign ?? callsign, master: master, type: master?.type ?? guessed)
        }
        guard !changes.isEmpty else { return nil }
        self.alarm = alarm
        self.changes = changes
        self.vehicles = vehicles
    }

    public init?(alarm: AlamosAlarm, state: MissionState, masterUnits: [MasterUnit] = []) {
        self.init(alarm: alarm, mission: state.mission, units: state.units, patients: state.patients, masterUnits: masterUnits)
    }

    /// Einsätze von vor Schritt 143 ohne gemerkten Stand: Fahrzeuge und Patienten aus dem
    /// Einsatz, Stichwort, Ort und Alarmtext gelten als bekannt.
    static func legacyBaseline(alarm: AlamosAlarm, units: [MissionUnit], patients: [Patient]) -> AlarmSnapshot {
        var snapshot = AlarmSnapshot(alarm.data)
        snapshot.vehicleKeys = units.compactMap(\.matchKey)
        snapshot.patientKeys = patients.compactMap(\.dispatchPatientNumber)
        return snapshot
    }

    /// Tagebucheintrag beim Übernehmen.
    var journalText: String {
        var lines = ["Änderung aus Alamos FE2 übernommen (Einsatznummer \(alarm.externalId), Stand \(alarm.revision))."]
        if let keyword = changes.keyword { lines.append("Stichwort: \(keyword)") }
        if let address = changes.address { lines.append("Einsatzort: \(address)") }
        if !changes.messageLines.isEmpty { lines.append("Alarmtext ergänzt:\n" + changes.messageLines.joined(separator: "\n")) }
        if !changes.callsigns.isEmpty { lines.append("Nachalarmiert: " + changes.callsigns.joined(separator: ", ")) }
        if !changes.patients.isEmpty { lines.append("Weitere gemeldete Patienten: \(changes.patients.count)") }
        return lines.joined(separator: "\n")
    }
}

/// Neuen FE2-Stand in den Einsatz übernehmen: neue Fahrzeuge und Patienten anlegen,
/// Änderungen im Tagebuch vermerken, Stand merken (Schritt 143).
public struct ApplyAlarmUpdate: MissionCommand {
    public let alarm: AlamosAlarm
    public let masterUnits: [MasterUnit]

    public init(alarm: AlamosAlarm, masterUnits: [MasterUnit] = []) {
        self.alarm = alarm
        self.masterUnits = masterUnits
    }

    @discardableResult
    public func execute(_ draft: inout MissionDraft) throws -> AlarmUpdate {
        guard let update = AlarmUpdate(
            alarm: alarm,
            mission: draft.mission,
            units: draft.active(MissionUnit.self),
            patients: draft.active(Patient.self),
            masterUnits: masterUnits
        ) else {
            throw CommandError.invalid("Dieser Stand aus Alamos FE2 ist schon übernommen.")
        }
        let coordinate = alarm.data.location?.geoCoordinate
        try draft.updateMission {
            $0.externalAlarm?.revision = alarm.revision
            $0.externalAlarm?.applied = AlarmSnapshot(alarm.data)
            $0.externalAlarm?.dismissedRevision = nil
            if $0.coordinate == nil, let coordinate { $0.coordinate = coordinate }
        }
        _ = try draft.addJournalEntry(text: update.journalText, origin: .automatic)
        draft.log(.mission, "Änderung aus Alamos FE2 übernommen (Stand \(alarm.revision))", subject: .mission(draft.missionID))
        try AlarmImport.addVehicles(update.vehicles, to: &draft)
        for reported in update.changes.patients { try AlarmImport.addReported(reported, to: &draft) }
        return update
    }
}

/// Hinweis auf einen neuen FE2-Stand ausblenden, ohne zu übernehmen (Schritt 143).
/// Beim nächsten Stand erscheint er wieder – dann mit allen Änderungen seit der letzten Übernahme.
public struct DismissAlarmUpdate: MissionCommand {
    public let revision: Int

    public init(revision: Int) {
        self.revision = revision
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard draft.mission.externalAlarm != nil else { throw CommandError.invalid("Der Einsatz ist nicht mit Alamos FE2 verknüpft.") }
        try draft.updateMission { $0.externalAlarm?.dismissedRevision = revision }
        draft.log(.mission, "Änderung aus Alamos FE2 nicht übernommen (Stand \(revision))", subject: .mission(draft.missionID))
    }
}

/// Einsatz mit einem FE2-Einsatz verknüpfen, ohne etwas anzulegen; der angegebene Stand
/// gilt als übernommen (Schritt 143, Beispieldaten; später „Mit FE2 verknüpfen“).
public struct LinkExternalAlarm: MissionCommand {
    public let alarm: AlamosAlarm

    public init(alarm: AlamosAlarm) {
        self.alarm = alarm
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let reference = ExternalAlarmReference(externalID: alarm.externalId, revision: alarm.revision, importedAt: draft.context.now, applied: AlarmSnapshot(alarm.data))
        try draft.updateMission { $0.externalAlarm = reference }
        draft.log(.mission, "Mit Alamos FE2 verknüpft (Einsatznummer \(alarm.externalId), Stand \(alarm.revision))", subject: .mission(draft.missionID))
    }
}
