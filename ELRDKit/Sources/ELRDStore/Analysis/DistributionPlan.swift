import Foundation
import ELRDDomain

// MARK: - Verteilungsvorschlag Kliniken (Schritt 108)

/// Vorschlag für einen Patienten: Zielklinik mit Begründung.
public struct DistributionProposal: Identifiable, Equatable, Sendable {
    public let patientID: PatientID
    public let number: String
    public let triage: Sichtungskategorie
    public let traumaRoom: TraumaRoom
    public let hospital: HospitalSnapshot
    /// Luftlinie Einsatzort → Klinik in Metern (`nil` = Koordinaten fehlen).
    public let distanceMeters: Double?
    public let reason: String

    public var id: PatientID { patientID }
}

/// Patient, für den es keinen Vorschlag gibt.
public struct UndistributedPatient: Identifiable, Equatable, Sendable {
    public let patientID: PatientID
    public let number: String
    public let triage: Sichtungskategorie
    public let reason: String

    public var id: PatientID { patientID }
}

/// Ergebnis: Vorschläge für alle gesichteten Patienten ohne Zielklinik. Die
/// Einsatzleitung bestätigt sie je Patient oder ändert sie (E113).
public struct DistributionPlan: Equatable, Sendable {
    public let proposals: [DistributionProposal]
    public let undistributed: [UndistributedPatient]
    /// Mindestens eine Klinik mit eingetragenem Kontingent.
    public let hasQuotas: Bool

    public var isEmpty: Bool { proposals.isEmpty && undistributed.isEmpty }
}

public extension HospitalDistribution {
    /// Schlägt je Patient (SK1–SK3, ohne Zielklinik, noch vor Ort) die nächstgelegene
    /// Klinik mit freiem Kontingent seiner SK vor.
    ///
    /// - Reihenfolge: SK1 vor SK2 vor SK3, innerhalb einer SK Schockraum-Bedarf zuerst,
    ///   dann nach Anlage – so bekommen die dringendsten Patienten die nächsten Plätze.
    /// - Nur ausdrücklich eingetragene Plätze zählen; eine SK ohne Kontingent nimmt
    ///   keine Vorschläge an.
    /// - Bereits zugewiesene Patienten belegen ihr Kontingent; jeder Vorschlag
    ///   belegt einen weiteren Platz.
    /// - Entfernung als Luftlinie vom Einsatzort; Kliniken ohne Koordinaten kommen
    ///   nach allen mit bekannter Entfernung.
    /// - Schockraum: Welche Klinik einen hat, ist nicht hinterlegt – der Bedarf
    ///   steht deshalb nur in der Begründung (Anmeldung nicht vergessen).
    static func propose(_ state: MissionState, hospitals: [MasterHospital]) -> DistributionPlan {
        let eligible = state.patients.active
            .filter { $0.outcome == nil && $0.destination == nil && $0.triage.isTransportPriority }
            .sorted(by: proposalOrder)
        let quotas = state.mission.hospitalQuotas ?? []
        guard !quotas.isEmpty else {
            return DistributionPlan(
                proposals: [],
                undistributed: eligible.map {
                    UndistributedPatient(patientID: $0.id, number: "\($0.number)", triage: $0.triage, reason: "Keine Kontingente eingetragen")
                },
                hasQuotas: false
            )
        }

        let origin = state.mission.coordinate
        var candidates: [Candidate] = loads(state).compactMap { load in
            guard let quota = load.quota else { return nil }
            let snapshot = resolvedHospital(load, hospitals: hospitals)
            var remaining: [Sichtungskategorie: Int] = [:]
            for triage in [Sichtungskategorie.sk1, .sk2, .sk3] {
                guard let limit = quota.limit(for: triage) else { continue }
                remaining[triage] = limit - (load.counts[triage] ?? 0)
            }
            let distance = origin.flatMap { origin in snapshot.coordinate.map { origin.distance(to: $0) } }
            return Candidate(hospital: snapshot, remaining: remaining, distance: distance)
        }

        var proposals: [DistributionProposal] = []
        var undistributed: [UndistributedPatient] = []
        for patient in eligible {
            let triage = patient.triage
            let indices = candidates.indices.filter { (candidates[$0].remaining[triage] ?? 0) > 0 }
            guard let best = indices.min(by: { candidateOrder(candidates[$0], candidates[$1], triage: triage) }) else {
                undistributed.append(UndistributedPatient(
                    patientID: patient.id, number: "\(patient.number)", triage: triage,
                    reason: "Kein freier Platz für \(triage.shortName)"
                ))
                continue
            }
            candidates[best].remaining[triage, default: 0] -= 1
            let candidate = candidates[best]
            proposals.append(DistributionProposal(
                patientID: patient.id,
                number: "\(patient.number)",
                triage: triage,
                traumaRoom: patient.traumaRoom,
                hospital: candidate.hospital,
                distanceMeters: candidate.distance,
                reason: reason(triage: triage, traumaRoom: patient.traumaRoom, distance: candidate.distance, hasOrigin: origin != nil)
            ))
        }
        return DistributionPlan(proposals: proposals, undistributed: undistributed, hasQuotas: true)
    }

    /// Klinik einer Zeile: Stammdaten (mit Adresse und Koordinaten) vor dem, was am
    /// Patienten steht, sonst nur der Name aus dem Kontingent.
    static func resolvedHospital(_ load: HospitalLoad, hospitals: [MasterHospital]) -> HospitalSnapshot {
        let master = hospitals.first { master in
            if let id = load.quota?.masterHospitalID ?? load.hospital?.masterHospitalID { return master.id == id }
            return HospitalQuota.key(master.name) == HospitalQuota.key(load.name)
        }
        return master?.snapshot
            ?? load.hospital
            ?? HospitalSnapshot(name: load.name, masterHospitalID: load.quota?.masterHospitalID)
    }

    /// Entfernung lesbar: „850 m“, „4,2 km“.
    static func distanceText(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int((meters / 10).rounded()) * 10) m" }
        let km = (meters / 100).rounded() / 10
        return km.formatted(.number.precision(.fractionLength(km < 10 ? 1 : 0)).locale(Locale(identifier: "de_DE"))) + " km"
    }

    private struct Candidate {
        let hospital: HospitalSnapshot
        var remaining: [Sichtungskategorie: Int]
        let distance: Double?
    }

    private static func proposalOrder(_ lhs: Patient, _ rhs: Patient) -> Bool {
        let rank: (Patient) -> Int = { patient in
            switch patient.triage {
            case .sk1: 0
            case .sk2: 1
            default: 2
            }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        let lhsRoom = lhs.traumaRoom != .none
        let rhsRoom = rhs.traumaRoom != .none
        if lhsRoom != rhsRoom { return lhsRoom }
        if lhs.metadata.createdAt != rhs.metadata.createdAt { return lhs.metadata.createdAt < rhs.metadata.createdAt }
        return lhs.number < rhs.number
    }

    /// Nächste zuerst; ohne Entfernung ans Ende. Bei Gleichstand die Klinik mit
    /// mehr freien Plätzen, dann alphabetisch (damit der Vorschlag stabil bleibt).
    private static func candidateOrder(_ lhs: Candidate, _ rhs: Candidate, triage: Sichtungskategorie) -> Bool {
        switch (lhs.distance, rhs.distance) {
        case let (l?, r?) where l != r: return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let lhsFree = lhs.remaining[triage] ?? 0
        let rhsFree = rhs.remaining[triage] ?? 0
        if lhsFree != rhsFree { return lhsFree > rhsFree }
        return lhs.hospital.name.localizedStandardCompare(rhs.hospital.name) == .orderedAscending
    }

    private static func reason(triage: Sichtungskategorie, traumaRoom: TraumaRoom, distance: Double?, hasOrigin: Bool) -> String {
        var parts: [String] = []
        if let distance {
            parts.append("Nächste Klinik mit freiem Platz für \(triage.shortName) (\(distanceText(distance)))")
        } else {
            parts.append("Freier Platz für \(triage.shortName)" + (hasOrigin ? ", Entfernung unbekannt" : ""))
        }
        if traumaRoom != .none {
            parts.append("\(traumaRoom.displayName) anmelden")
        }
        return parts.joined(separator: " · ")
    }
}

private extension Sichtungskategorie {
    /// SK1–SK3: Patienten, die eine Zielklinik brauchen.
    var isTransportPriority: Bool { self == .sk1 || self == .sk2 || self == .sk3 }
}

/// Übernimmt bestätigte Vorschläge (Schritt 108): setzt je Patient die Zielklinik
/// und hält die Übernahme im Protokoll fest (nur Nummern und Kliniken).
public struct ApplyDistribution: MissionCommand {
    public struct Assignment: Equatable, Sendable {
        public let patientID: PatientID
        public let hospital: HospitalSnapshot

        public init(patientID: PatientID, hospital: HospitalSnapshot) {
            self.patientID = patientID
            self.hospital = hospital
        }
    }

    public let assignments: [Assignment]

    public init(_ assignments: [Assignment]) {
        self.assignments = assignments
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard !assignments.isEmpty else { return }
        for assignment in assignments {
            try SetDestination(patientID: assignment.patientID, hospital: assignment.hospital).execute(&draft)
        }
        let count = assignments.count
        draft.log(.mission, count == 1 ? "Verteilungsvorschlag für 1 Patienten übernommen" : "Verteilungsvorschlag für \(count) Patienten übernommen")
    }
}
