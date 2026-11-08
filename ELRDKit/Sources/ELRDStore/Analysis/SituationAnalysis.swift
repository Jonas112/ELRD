import Foundation
import ELRDDomain

// MARK: - Lagemeldung (Schritt 67)

/// Lagemeldung aus den Einsatzdaten – schlank, zum Vorlesen am Funk. Kein
/// vorgeschriebenes ILS-Schema; Reihenfolge: Wer/Wo, Lage, Verletzte, Transport,
/// Kräfte, Gefahren, Nachforderung.
public enum SituationReport {
    public static func text(for state: MissionState, now: Date, calendar: Calendar = .current) -> String {
        let mission = state.mission
        var lines: [String] = []
        let time = now.formatted(date: .omitted, time: .shortened)
        var head = "Lagemeldung \(time) Uhr – Einsatz \(mission.displayNumber(calendar: calendar)), \(mission.title)"
        if !mission.location.isEmpty { head += ", \(mission.location)" }
        lines.append(head + ".")

        if let note = mission.situationNote?.trimmed, !note.isEmpty {
            lines.append("Lage: \(note)")
        }

        let patients = state.patients.active
        if patients.isEmpty {
            lines.append("Bisher keine Patienten.")
        } else {
            let counts = Patient.countsByTriage(patients)
            let parts = [Sichtungskategorie.sk1, .sk2, .sk3, .unverletzt, .ungesichtet, .verstorben].compactMap { triage -> String? in
                guard let count = counts[triage], count > 0 else { return nil }
                return "\(triage.shortName) \(count)"
            }
            lines.append("Patienten: \(patients.count) gesamt – \(parts.joined(separator: ", ")).")
            let status = PatientStatusCounts(patients: patients)
            var transport: [String] = []
            if status.inTransport > 0 { transport.append("\(status.inTransport) abtransportiert") }
            if status.assigned > 0 { transport.append("\(status.assigned) mit Einheit") }
            if status.waiting > 0 { transport.append("\(status.waiting) warten") }
            if status.released > 0 { transport.append("\(status.released) entlassen") }
            if !transport.isEmpty { lines.append("Transport: \(transport.joined(separator: ", ")).") }
        }

        let forces = ForceOverview(state: state)
        if forces.unitCount > 0 {
            var text = "Kräfte: \(forces.unitCount) Einheiten vor Ort (\(forces.typeSummary))"
            if let strength = forces.strengthText { text += ", \(strength)" }
            lines.append(text + ".")
        }
        if forces.placeholderCount > 0 {
            lines.append("Angefordert, noch nicht vor Ort: \(forces.placeholderSummary).")
        }

        let sections = state.activeSections.filter { !$0.isInitial || state.activeSections.count == 1 }
        if state.activeSections.count > 1 {
            let names = sections.map { section in
                section.leaderName.map { "\(section.name) (\($0))" } ?? section.name
            }
            lines.append("Abschnitte: \(names.joined(separator: ", ")).")
        }

        if let hazards = mission.hazards?.trimmed, !hazards.isEmpty {
            lines.append("Gefahren: \(hazards)")
        }

        let demand = ResourceDemand.calculate(state)
        lines.append(demand.hasShortfall ? "Nachforderung: \(demand.missingSummary)." : "Keine weitere Nachforderung.")
        return lines.joined(separator: "\n")
    }
}

/// Speichert eine Lagemeldung im Tagebuch und übernimmt Lage und Gefahren in den Einsatz.
public struct AddSituationReport: MissionCommand {
    public let text: String
    public let situationNote: String?
    public let hazards: String?

    public init(text: String, situationNote: String? = nil, hazards: String? = nil) {
        self.text = text
        self.situationNote = situationNote
        self.hazards = hazards
    }

    @discardableResult
    public func execute(_ draft: inout MissionDraft) throws -> JournalEntry {
        let note = situationNote?.trimmed
        let danger = hazards?.trimmed
        if note != draft.mission.situationNote || danger != draft.mission.hazards {
            _ = try draft.updateMission {
                $0.situationNote = note?.isEmpty == true ? nil : note
                $0.hazards = danger?.isEmpty == true ? nil : danger
            }
        }
        var entry = try draft.addJournalEntry(text: text.trimmed, origin: .manual)
        entry = try draft.update(JournalEntry.self, id: entry.id) { $0.category = .situationReport }
        draft.log(.journal, "Lagemeldung \(entry.number) erfasst", subject: .journalEntry(entry.id))
        return entry
    }
}

public extension MissionState {
    /// Zeit der letzten Lagemeldung (Schritt 69).
    var lastSituationReportAt: Date? {
        journal.active.filter { $0.category == .situationReport }.map(\.occurredAt).max()
    }
}

// MARK: - Transport-Board (Schritt 70)

/// Spalte des Transport-Boards.
public enum TransportStage: Int, CaseIterable, Sendable, Identifiable {
    /// Noch ohne Transportmittel.
    case waiting
    /// Transportmittel eingeteilt, noch nicht abgefahren.
    case assigned
    /// Abgefahren.
    case departed

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .waiting: "Wartet"
        case .assigned: "Eingeteilt"
        case .departed: "Abgefahren"
        }
    }
}

public enum TransportBoard {
    /// Spalte eines Patienten; `nil` für entlassene, verstorbene und unverletzte
    /// ohne Transport (gehören nicht aufs Board).
    public static func stage(of patient: Patient, units: [MissionUnit]) -> TransportStage? {
        switch patient.status {
        case .released: return nil
        case .inTransport: return .departed
        case .waiting, .assigned:
            guard [.sk1, .sk2, .sk3, .ungesichtet].contains(patient.triage) || patient.hasTransportUnit(in: units) else { return nil }
            return patient.hasTransportUnit(in: units) ? .assigned : .waiting
        }
    }

    /// Patienten je Spalte in Transportreihenfolge: schwerste zuerst, bei gleicher
    /// SK wer am längsten wartet. Abgefahrene: zuletzt abgefahren oben.
    public static func columns(_ state: MissionState) -> [TransportStage: [Patient]] {
        var result: [TransportStage: [Patient]] = [.waiting: [], .assigned: [], .departed: []]
        for patient in state.patients.active {
            guard let stage = stage(of: patient, units: state.units) else { continue }
            result[stage, default: []].append(patient)
        }
        for stage in [TransportStage.waiting, .assigned] {
            result[stage]?.sort { lhs, rhs in
                let left = (urgency(lhs.triage), lhs.metadata.createdAt, lhs.number)
                let right = (urgency(rhs.triage), rhs.metadata.createdAt, rhs.number)
                return left < right
            }
        }
        result[.departed]?.sort { ($0.outcome?.date ?? .distantPast) > ($1.outcome?.date ?? .distantPast) }
        return result
    }

    private static func urgency(_ triage: Sichtungskategorie) -> Int {
        switch triage {
        case .sk1: 0
        case .sk2: 1
        case .ungesichtet: 2
        case .sk3: 3
        default: 4
        }
    }
}

// MARK: - Klinikverteilung (Schritt 71)

/// Auslastung einer Klinik gegen ihr Kontingent.
public struct HospitalLoad: Identifiable, Equatable, Sendable {
    public let name: String
    public let hospital: HospitalSnapshot?
    public let quota: HospitalQuota?
    public let counts: [Sichtungskategorie: Int]

    public var id: String { quota?.id ?? HospitalQuota.key(name) }
    public var total: Int { counts.values.reduce(0, +) }

    /// Noch freie Plätze einer SK (`nil` = kein Kontingent bekannt).
    public func remaining(_ triage: Sichtungskategorie) -> Int? {
        quota?.limit(for: triage).map { $0 - (counts[triage] ?? 0) }
    }

    public func isOverloaded(_ triage: Sichtungskategorie) -> Bool {
        (remaining(triage) ?? 0) < 0
    }

    public var overloadedTriages: [Sichtungskategorie] {
        [.sk1, .sk2, .sk3].filter(isOverloaded)
    }

    public var isFull: Bool {
        guard let quota else { return false }
        return [Sichtungskategorie.sk1, .sk2, .sk3].allSatisfy { triage in
            guard quota.limit(for: triage) != nil else { return true }
            return (remaining(triage) ?? 1) <= 0
        }
    }
}

public enum HospitalDistribution {
    /// Alle Kliniken mit Kontingent oder zugewiesenen Patienten, meistbelegte zuerst.
    public static func loads(_ state: MissionState) -> [HospitalLoad] {
        var loads: [String: (hospital: HospitalSnapshot?, quota: HospitalQuota?, counts: [Sichtungskategorie: Int], name: String)] = [:]
        let quotas = state.mission.hospitalQuotas ?? []
        for quota in quotas {
            loads[quota.id] = (nil, quota, [:], quota.hospitalName)
        }
        for patient in state.patients.active where patient.status != .released {
            guard let destination = patient.destination else { continue }
            let quota = quotas.first { $0.matches(destination) }
            let key = quota?.id ?? HospitalQuota.key(destination.name)
            var entry = loads[key] ?? (destination, quota, [:], destination.name)
            entry.hospital = entry.hospital ?? destination
            entry.counts[patient.triage, default: 0] += 1
            loads[key] = entry
        }
        return loads.values
            .map { HospitalLoad(name: $0.name, hospital: $0.hospital, quota: $0.quota, counts: $0.counts) }
            .sorted { lhs, rhs in
                lhs.total != rhs.total ? lhs.total > rhs.total : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Auslastung einer bestimmten Klinik (für die Klinikauswahl).
    public static func load(of hospital: HospitalSnapshot, in state: MissionState) -> HospitalLoad? {
        loads(state).first { load in
            load.quota?.matches(hospital) ?? (HospitalQuota.key(load.name) == HospitalQuota.key(hospital.name))
        }
    }
}

/// Setzt oder entfernt das Kontingent einer Klinik.
public struct SetHospitalQuota: MissionCommand {
    public let quota: HospitalQuota

    public init(_ quota: HospitalQuota) {
        self.quota = quota
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard !quota.hospitalName.isEmpty else { throw CommandError.invalid("Klinik fehlt") }
        let target = quota
        _ = try draft.updateMission { $0.setQuota(target) }
        let parts = [Sichtungskategorie.sk1, .sk2, .sk3].compactMap { triage in
            target.limit(for: triage).map { "\(triage.shortName) \($0)" }
        }
        draft.log(.mission, "Kontingent \(target.hospitalName): \(parts.isEmpty ? "ohne Grenze" : parts.joined(separator: ", "))", subject: .mission(draft.missionID))
    }
}

/// Entfernt eine Klinik aus der Kontingentliste.
public struct RemoveHospitalQuota: MissionCommand {
    public let quotaID: String

    public init(quotaID: String) {
        self.quotaID = quotaID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let quota = draft.mission.hospitalQuotas?.first(where: { $0.id == quotaID }) else { return }
        let id = quotaID
        _ = try draft.updateMission { $0.removeQuota(id: id) }
        draft.log(.mission, "Kontingent \(quota.hospitalName) entfernt", subject: .mission(draft.missionID))
    }
}

// MARK: - Kräfteübersicht (Schritt 73)

/// Einheiten und Stärke des Einsatzes.
public struct ForceOverview: Equatable, Sendable {
    public struct SectionForce: Identifiable, Equatable, Sendable {
        public let section: MissionSection
        public let units: [MissionUnit]
        public let strength: Int
        public let unknownCrew: Int
        public var id: SectionID { section.id }
    }

    /// Tatsächliche Fahrzeuge (ohne Platzhalter).
    public let unitCount: Int
    public let placeholderCount: Int
    public let byType: [UnitType: Int]
    public let placeholdersByType: [UnitType: Int]
    /// Summe der eingetragenen Besatzungen.
    public let strength: Int
    /// Fahrzeuge ohne Besatzungsangabe.
    public let unknownCrew: Int
    public let sections: [SectionForce]

    public init(state: MissionState) {
        let units = state.activeUnits
        let real = units.filter { !$0.isPlaceholder }
        unitCount = real.count
        placeholderCount = units.count - real.count
        byType = Dictionary(grouping: real, by: \.type).mapValues(\.count)
        placeholdersByType = Dictionary(grouping: units.filter(\.isPlaceholder), by: \.type).mapValues(\.count)
        strength = real.compactMap(\.crewCount).reduce(0, +)
        unknownCrew = real.filter { $0.crewCount == nil }.count
        let initial = state.activeSections.first(where: \.isInitial)?.id
        sections = state.activeSections.map { section in
            let members = real.filter { ($0.sectionID ?? initial) == section.id }
            return SectionForce(
                section: section,
                units: members,
                strength: members.compactMap(\.crewCount).reduce(0, +),
                unknownCrew: members.filter { $0.crewCount == nil }.count
            )
        }
    }

    public var typeSummary: String { Self.summary(byType) }
    public var placeholderSummary: String { Self.summary(placeholdersByType) }

    /// „Stärke 14“ oder „Stärke mind. 14 (2 ohne Angabe)“; `nil`, wenn nichts bekannt.
    public var strengthText: String? {
        guard strength > 0 else { return nil }
        return unknownCrew > 0 ? "Stärke mind. \(strength) (\(unknownCrew) ohne Angabe)" : "Stärke \(strength)"
    }

    static func summary(_ counts: [UnitType: Int]) -> String {
        UnitType.allCases.compactMap { type in
            guard let count = counts[type], count > 0 else { return nil }
            return "\(count) \(type.shortName)"
        }
        .joined(separator: ", ")
    }
}

/// Setzt eine Funktion der Einsatzleitung (leer = entfernen).
public struct SetLeadershipPosition: MissionCommand {
    public let position: LeadershipPosition

    public init(_ position: LeadershipPosition) {
        self.position = position
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let target = position
        let before = draft.mission.position(target.role)
        guard before != target else { return }
        _ = try draft.updateMission { $0.setPosition(target) }
        let text = target.isEmpty ? "entfernt" : [target.name, target.callsign, target.radioChannel].filter { !$0.isEmpty }.joined(separator: " · ")
        draft.log(.mission, "\(target.role.shortName): \(text)", subject: .mission(draft.missionID))
    }
}

/// Leitung und Funkkanal eines Abschnitts.
public struct SetSectionLeader: MissionCommand {
    public let sectionID: SectionID
    public let name: String
    public let callsign: String
    public let radioChannel: String

    public init(sectionID: SectionID, name: String, callsign: String, radioChannel: String) {
        self.sectionID = sectionID
        self.name = name
        self.callsign = callsign
        self.radioChannel = radioChannel
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let values = [name, callsign, radioChannel].map { $0.trimmed }
        let after = try draft.update(MissionSection.self, id: sectionID) { section in
            section.leaderName = values[0].isEmpty ? nil : values[0]
            section.leaderCallsign = values[1].isEmpty ? nil : values[1]
            section.radioChannel = values[2].isEmpty ? nil : values[2]
        }
        draft.log(.section, "Leitung \(after.name): \(values.filter { !$0.isEmpty }.joined(separator: " · "))", subject: .section(after.id))
    }
}

/// Patienten nach Versorgungsstand für die Lage.
public struct PatientStatusCounts: Equatable, Sendable {
    public let waiting: Int
    public let assigned: Int
    public let inTransport: Int
    public let released: Int

    public init(patients: [Patient]) {
        let active = patients.active
        waiting = active.filter { $0.status == .waiting }.count
        assigned = active.filter { $0.status == .assigned }.count
        inTransport = active.filter { $0.status == .inTransport }.count
        released = active.filter { $0.status == .released }.count
    }
}

// MARK: - Patientenanhängekarte (Schritt 72)

public extension MissionState {
    /// Patient mit dieser Kartennummer (gelöschte zählen nicht).
    func patient(withTag raw: String) -> Patient? {
        guard let tag = Patient.normalizedTag(raw) else { return nil }
        return patients.active.first { $0.tagNumber == tag }
    }
}

/// Kartennummer eines Patienten setzen oder entfernen.
public struct SetPatientTag: MissionCommand {
    public let patientID: PatientID
    public let tagNumber: String?

    public init(patientID: PatientID, tagNumber: String?) {
        self.patientID = patientID
        self.tagNumber = tagNumber.flatMap(Patient.normalizedTag)
    }

    public func execute(_ draft: inout MissionDraft) throws {
        if let tagNumber, let other = draft.all(Patient.self).first(where: { !$0.isDeleted && $0.tagNumber == tagNumber && $0.id != patientID }) {
            throw CommandError.invalid("Karte \(tagNumber) gehört schon zu Patient \(other.number).")
        }
        let tag = tagNumber
        let after = try draft.update(Patient.self, id: patientID) { $0.tagNumber = tag }
        draft.log(.patient, "Patient \(after.number): Anhängekarte \(tag ?? "entfernt")", subject: .patient(after.id))
    }
}

// MARK: - Hilfen

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
