import Foundation
import ELRDDomain

// MARK: - Übungsleiter-Modus (Schritt 138)

/// Einlage anlegen oder ändern (nur bei Übungen).
public struct SaveExerciseInject: MissionCommand {
    public let inject: ExerciseInject

    public init(_ inject: ExerciseInject) {
        self.inject = inject
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard draft.mission.isExerciseMission else { throw CommandError.invalid("Einlagen gibt es nur bei Übungen.") }
        guard !inject.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw CommandError.invalid("Bitte einen Titel eingeben.") }
        let target = inject
        var isNew = false
        _ = try draft.updateMission { mission in
            var list = mission.exerciseInjects ?? []
            if let index = list.firstIndex(where: { $0.id == target.id }) {
                list[index] = target
            } else {
                list.append(target)
                isNew = true
            }
            list.sort { ($0.minute ?? Int.max, $0.title) < ($1.minute ?? Int.max, $1.title) }
            mission.exerciseInjects = list
        }
        draft.log(.mission, "Übungsleitung: Einlage „\(target.title)“ \(isNew ? "geplant" : "geändert")", subject: .mission(draft.missionID))
    }
}

/// Einlage entfernen (noch nicht eingespielte).
public struct RemoveExerciseInject: MissionCommand {
    public let injectID: UUID

    public init(_ injectID: UUID) {
        self.injectID = injectID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard let inject = draft.mission.exerciseInjects?.first(where: { $0.id == injectID }) else { return }
        _ = try draft.updateMission { mission in
            mission.exerciseInjects?.removeAll { $0.id == injectID }
            if mission.exerciseInjects?.isEmpty == true { mission.exerciseInjects = nil }
        }
        draft.log(.mission, "Übungsleitung: Einlage „\(inject.title)“ entfernt", subject: .mission(draft.missionID))
    }
}

/// Einlage einspielen: Wirkung im Einsatz und Meldung an alle.
public struct ReleaseExerciseInject: MissionCommand {
    public let injectID: UUID

    public init(_ injectID: UUID) {
        self.injectID = injectID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        guard draft.mission.isExerciseMission else { throw CommandError.invalid("Einlagen gibt es nur bei Übungen.") }
        guard let inject = draft.mission.exerciseInjects?.first(where: { $0.id == injectID }) else {
            throw CommandError.invalid("Diese Einlage gibt es nicht mehr.")
        }
        guard !inject.isReleased else { return }
        var text = inject.text
        switch inject.kind {
        case .patients:
            for entry in inject.patients ?? [] {
                let patient = try AddPatient(triage: .ungesichtet).execute(&draft)
                try draft.update(Patient.self, id: patient.id) {
                    $0.notes = ExerciseScore.injectMarker + entry.findings
                    $0.expectedTriage = entry.expected
                }
            }
        case .hospitalFull:
            // Klinik aus der Einlage, sonst die mit den meisten zugewiesenen Patienten.
            let name = inject.hospitalName ?? Self.busiestHospital(in: draft)
            if let name {
                var quota = draft.mission.hospitalQuotas?.first { HospitalQuota.key($0.hospitalName) == HospitalQuota.key(name) }
                    ?? HospitalQuota(hospitalName: name)
                for triage in [Sichtungskategorie.sk1, .sk2, .sk3] {
                    // Bereits Zugewiesene bleiben – mehr gibt es nicht.
                    let assigned = draft.all(Patient.self).filter {
                        !$0.isDeleted && $0.triage == triage && $0.destination.map { HospitalQuota.key($0.name) == HospitalQuota.key(name) } == true
                    }.count
                    quota.setLimit(assigned, for: triage)
                }
                try SetHospitalQuota(quota).execute(&draft)
                text = "\(name): \(inject.text)"
            }
        case .deterioration:
            let candidate = Patient.sortedByNumber(draft.all(Patient.self).filter { !$0.isDeleted && $0.outcome == nil })
                .first { $0.triage == .sk2 } ?? Patient.sortedByNumber(draft.all(Patient.self).filter { !$0.isDeleted && $0.outcome == nil }).first
            if let candidate {
                try draft.update(Patient.self, id: candidate.id) {
                    $0.expectedTriage = .sk1
                    $0.notes = [$0.notes, ExerciseScore.injectMarker + inject.text].filter { !$0.isEmpty }.joined(separator: "\n")
                }
                text = "Patient \(candidate.number): \(inject.text)"
            }
        case .unitOut, .message:
            break
        }
        let now = draft.context.now
        _ = try draft.updateMission { mission in
            if let index = mission.exerciseInjects?.firstIndex(where: { $0.id == inject.id }) {
                mission.exerciseInjects?[index].releasedAt = now
            }
        }
        _ = try SendMessage("ÜBUNG – \(inject.title): \(text)", kind: .warning).execute(&draft)
        draft.log(.mission, "Übungsleitung: Einlage „\(inject.title)“ eingespielt", subject: .mission(draft.missionID))
    }

    private static func busiestHospital(in draft: MissionDraft) -> String? {
        let names = draft.all(Patient.self).filter { !$0.isDeleted }.compactMap { $0.destination?.name }
        return Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}

/// Alle fälligen geplanten Einlagen einspielen (Gerät der Einsatzleitung, minütlich).
public struct ReleaseDueExerciseInjects: MissionCommand {
    public let now: Date

    public init(now: Date) {
        self.now = now
    }

    public func execute(_ draft: inout MissionDraft) throws -> Int {
        guard draft.mission.isExerciseMission, !draft.mission.isClosed else { return 0 }
        let start = draft.mission.startedAt
        let due = (draft.mission.exerciseInjects ?? []).filter { $0.isDue(missionStart: start, now: now) }
        for inject in due {
            try ReleaseExerciseInject(inject.id).execute(&draft)
        }
        return due.count
    }
}
