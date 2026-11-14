import Foundation
import ELRDDomain

/// Neuer Stand eines übernommenen FE2-Einsatzes gegenüber dem ELRD-Einsatz (Schritt 143).
///
/// Grundlage ist der zuletzt übernommene Stand (`ExternalAlarmReference.applied`).
/// Übernommen wird nur, was neu ist, und nur, was ausgewählt wird; nichts im Einsatz
/// wird überschrieben (E125, E129). Stichwort, Ort und Alarmtext landen im Tagebuch.
public struct AlarmUpdate: Hashable, Sendable {
    public let alarm: AlamosAlarm
    /// Neues seit der letzten Übernahme (Fahrzeuge nur, wenn noch nicht im Einsatz).
    public let changes: AlamosChanges
    /// Neue Fahrzeuge mit Stammdaten-Treffer (gleiche Reihenfolge wie `changes.callsigns`).
    public let vehicles: [AlarmImport.VehicleMatch]
    /// Zuletzt übernommener Stand (bei Einsätzen vor Schritt 143 aus dem Einsatz abgeleitet).
    public let baseline: AlarmSnapshot

    /// `nil`, wenn der Einsatz nicht zu diesem FE2-Einsatz gehört, der Hinweis für diesen
    /// Stand ausgeblendet ist oder nichts Neues offen ist.
    public init?(alarm: AlamosAlarm, mission: Mission, units: [MissionUnit], patients: [Patient], masterUnits: [MasterUnit] = []) {
        guard let reference = mission.externalAlarm, reference.externalID == alarm.externalId,
              alarm.revision > (reference.dismissedRevision ?? 0) else { return nil }
        let activeUnits = units.filter { !$0.metadata.isDeleted }
        let baseline = reference.applied ?? Self.legacyBaseline(alarm: alarm, units: activeUnits, patients: patients.filter { !$0.metadata.isDeleted })
        var changes = alarm.data.changes(since: baseline)
        // Schon im Einsatz (z. B. von Hand angelegt) → nicht noch einmal anbieten.
        let inMission = Set(activeUnits.compactMap(\.matchKey))
        changes.callsigns = changes.callsigns.filter { !inMission.contains(MasterDataMatching.key($0)) }
        guard !changes.isEmpty else { return nil }

        let byKey = Dictionary(masterUnits.map { ($0.matchKey, $0) }, uniquingKeysWith: { first, _ in first })
        let source = Dictionary(alarm.data.vehicles.compactMap { vehicle in vehicle.callsign.map { (MasterDataMatching.key($0), vehicle) } },
                                uniquingKeysWith: { first, _ in first })
        self.vehicles = changes.callsigns.map { callsign in
            let key = MasterDataMatching.key(callsign)
            let master = byKey[key]
            let guessed = source[key]?.guessedUnitType ?? .sonstiges
            return AlarmImport.VehicleMatch(callsign: master?.callsign ?? callsign, master: master, type: master?.type ?? guessed)
        }
        self.alarm = alarm
        self.changes = changes
        self.baseline = baseline
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

    /// Alles auswählen.
    public var fullSelection: AlarmUpdateSelection {
        AlarmUpdateSelection(
            keyword: changes.keyword != nil,
            address: changes.address != nil,
            message: !changes.messageLines.isEmpty,
            vehicleKeys: Set(changes.callsigns.map(MasterDataMatching.key)),
            patientKeys: Set(changes.patientKeys)
        )
    }

    /// Ausgewählte Fahrzeuge bzw. Patienten.
    func vehicles(in selection: AlarmUpdateSelection) -> [AlarmImport.VehicleMatch] {
        zip(changes.callsigns, vehicles).filter { selection.vehicleKeys.contains(MasterDataMatching.key($0.0)) }.map { $0.1 }
    }

    func patients(in selection: AlarmUpdateSelection) -> [AlamosPatient] {
        zip(changes.patients, changes.patientKeys).filter { selection.patientKeys.contains($0.1) }.map { $0.0 }
    }

    /// Neuer gemerkter Stand: nur Ausgewähltes gilt als übernommen.
    func snapshot(after selection: AlarmUpdateSelection) -> AlarmSnapshot {
        let current = AlarmSnapshot(alarm.data)
        var snapshot = baseline
        if selection.keyword {
            snapshot.keyword = current.keyword
            snapshot.keywordDescription = current.keywordDescription
        }
        if selection.address { snapshot.address = current.address }
        if selection.message { snapshot.message = current.message }
        // Fahrzeuge, die schon im Einsatz sind, gelten ebenfalls als erledigt.
        let offered = Set(changes.callsigns.map(MasterDataMatching.key))
        let done = current.vehicleKeys.filter { !offered.contains($0) || selection.vehicleKeys.contains($0) }
        snapshot.vehicleKeys = Self.merged(snapshot.vehicleKeys, done)
        snapshot.patientKeys = Self.merged(snapshot.patientKeys, changes.patientKeys.filter { selection.patientKeys.contains($0) })
        return snapshot
    }

    private static func merged(_ old: [String], _ new: [String]) -> [String] {
        var seen = Set(old)
        return old + new.filter { seen.insert($0).inserted }
    }

    /// Tagebucheintrag zur Auswahl.
    func journalText(for selection: AlarmUpdateSelection) -> String {
        var lines = ["Änderung aus Alamos FE2 übernommen (Einsatznummer \(alarm.externalId), Stand \(alarm.revision))."]
        if selection.keyword, let keyword = changes.keyword { lines.append("Stichwort: \(keyword)") }
        if selection.address, let address = changes.address { lines.append("Einsatzort: \(address)") }
        if selection.message, !changes.messageLines.isEmpty { lines.append("Alarmtext ergänzt:\n" + changes.messageLines.joined(separator: "\n")) }
        let chosenVehicles = vehicles(in: selection)
        if !chosenVehicles.isEmpty { lines.append("Nachalarmiert: " + chosenVehicles.map(\.callsign).joined(separator: ", ")) }
        let chosenPatients = patients(in: selection)
        if !chosenPatients.isEmpty { lines.append("Weitere gemeldete Patienten: \(chosenPatients.count)") }
        return lines.joined(separator: "\n")
    }
}

/// Auswahl beim Übernehmen eines neuen FE2-Stands (Schritt 143): Tagebuchvermerke,
/// einzelne Fahrzeuge (Schlüssel nach `MasterDataMatching.key`) und Patienten.
public struct AlarmUpdateSelection: Hashable, Sendable {
    public var keyword: Bool
    public var address: Bool
    public var message: Bool
    public var vehicleKeys: Set<String>
    public var patientKeys: Set<String>

    public init(keyword: Bool = false, address: Bool = false, message: Bool = false, vehicleKeys: Set<String> = [], patientKeys: Set<String> = []) {
        self.keyword = keyword
        self.address = address
        self.message = message
        self.vehicleKeys = vehicleKeys
        self.patientKeys = patientKeys
    }

    public var isEmpty: Bool { !keyword && !address && !message && vehicleKeys.isEmpty && patientKeys.isEmpty }

    /// Anzahl ausgewählter Punkte (für „Übernehmen (n)“).
    public var count: Int { [keyword, address, message].filter { $0 }.count + vehicleKeys.count + patientKeys.count }
}

/// Neuen FE2-Stand ganz oder teilweise übernehmen: ausgewählte Fahrzeuge und Patienten
/// anlegen, Vermerk im Tagebuch, Übernommenes merken. Nicht Ausgewähltes bleibt offen (Schritt 143).
public struct ApplyAlarmUpdate: MissionCommand {
    public let alarm: AlamosAlarm
    /// `nil`: alles übernehmen.
    public let selection: AlarmUpdateSelection?
    public let masterUnits: [MasterUnit]

    public init(alarm: AlamosAlarm, selection: AlarmUpdateSelection? = nil, masterUnits: [MasterUnit] = []) {
        self.alarm = alarm
        self.selection = selection
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
        let selection = selection ?? update.fullSelection
        guard !selection.isEmpty else { throw CommandError.invalid("Bitte mindestens einen Punkt auswählen.") }
        let snapshot = update.snapshot(after: selection)
        let coordinate = alarm.data.location?.geoCoordinate
        try draft.updateMission {
            $0.externalAlarm?.revision = alarm.revision
            $0.externalAlarm?.applied = snapshot
            $0.externalAlarm?.dismissedRevision = nil
            if $0.coordinate == nil, let coordinate { $0.coordinate = coordinate }
        }
        _ = try draft.addJournalEntry(text: update.journalText(for: selection), origin: .automatic)
        draft.log(.mission, "Änderung aus Alamos FE2 übernommen (Stand \(alarm.revision), \(selection.count) Punkte)", subject: .mission(draft.missionID))
        try AlarmImport.addVehicles(update.vehicles(in: selection), to: &draft)
        for reported in update.patients(in: selection) { try AlarmImport.addReported(reported, to: &draft) }
        return update
    }
}

/// Hinweis auf einen neuen FE2-Stand ausblenden, ohne zu übernehmen (Schritt 143).
/// Beim nächsten Stand erscheint er wieder – dann mit allem, was noch offen ist.
public struct DismissAlarmUpdate: MissionCommand {
    public let revision: Int

    public init(revision: Int) {
        self.revision = revision
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard draft.mission.externalAlarm != nil else { throw CommandError.invalid("Der Einsatz ist nicht mit Alamos FE2 verknüpft.") }
        try draft.updateMission { $0.externalAlarm?.dismissedRevision = revision }
        draft.log(.mission, "Änderung aus Alamos FE2 ausgeblendet (Stand \(revision))", subject: .mission(draft.missionID))
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
