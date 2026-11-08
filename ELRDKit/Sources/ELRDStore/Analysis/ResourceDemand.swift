import Foundation
import ELRDDomain

/// Nachforderungs-Rechner (Schritt 68): Welche Transportmittel fehlen für die
/// Patienten, die noch nicht abtransportiert sind?
///
/// Mindestbedarf je Patient (E87):
/// - SK 1: RTW **und** NEF – oder RTH allein
/// - SK 2: RTW
/// - SK 3: KTW (ersatzweise ein übriger RTW)
///
/// SK 1 braucht grundsätzlich einen Notarzt – je SK‑1-Patient ein eigenes NEF
/// (E92). In großer Not reicht ein RTW allein: Das zeigt `emergencyMissing`
/// (Notfall-Bedarf ohne NEF) zusätzlich an; nachgefordert wird der Normalbedarf.
///
/// Vorhanden sind alle Einheiten des Einsatzes, die nicht gerade einen Patienten
/// transportieren – auch Platzhalter (schon angefordert, Fahrzeug unterwegs).
public struct ResourceDemand: Equatable, Sendable {
    /// Typen, die der Rechner betrachtet, in Anzeigereihenfolge.
    public static let types: [UnitType] = [.rtw, .nef, .rth, .ktw]

    /// Patienten je SK, die noch einen Transport brauchen.
    public var patients: [Sichtungskategorie: Int] = [:]
    /// Verfügbare Einheiten je Typ (KTW-KatS zählt als KTW).
    public var available: [UnitType: Int] = [:]
    /// Davon eingeplant.
    public var used: [UnitType: Int] = [:]
    /// Fehlbedarf je Typ – das wird nachgefordert.
    public var missing: [UnitType: Int] = [:]
    /// Fehlbedarf im Notfall (SK 1 nur mit RTW, ohne Notarzt).
    public var emergencyMissing: [UnitType: Int] = [:]

    public var hasShortfall: Bool { missing.values.contains { $0 > 0 } }
    public var patientTotal: Int { patients.values.reduce(0, +) }

    /// „2 RTW, 1 NEF“ – leer, wenn nichts fehlt.
    public var missingSummary: String {
        Self.summary(missing)
    }

    public static func summary(_ counts: [UnitType: Int]) -> String {
        Self.types.compactMap { type in
            guard let count = counts[type], count > 0 else { return nil }
            return "\(count) \(type.shortName)"
        }
        .joined(separator: ", ")
    }

    public static func calculate(_ state: MissionState) -> ResourceDemand {
        var result = calculate(state, nefPerSK1: true)
        result.emergencyMissing = calculate(state, nefPerSK1: false).missing
        return result
    }

    static func calculate(_ state: MissionState, nefPerSK1: Bool) -> ResourceDemand {
        var result = ResourceDemand()
        let patients = state.patients.active
        let busy = Set(patients.filter { $0.status == .inTransport }.flatMap(\.unitIDs))

        var pool: [UnitType: Int] = [:]
        for unit in state.units.active where !busy.contains(unit.id) {
            guard let type = Self.poolType(unit.type) else { continue }
            pool[type, default: 0] += 1
        }
        result.available = pool

        let waiting = patients.filter { $0.outcome == nil }
        for triage in [Sichtungskategorie.sk1, .sk2, .sk3] {
            result.patients[triage] = waiting.filter { $0.triage == triage }.count
        }

        func take(_ type: UnitType) -> Bool {
            guard (pool[type] ?? 0) > 0 else { return false }
            pool[type, default: 0] -= 1
            result.used[type, default: 0] += 1
            return true
        }
        func lack(_ type: UnitType) { result.missing[type, default: 0] += 1 }

        // Schwerste zuerst: Knappe Mittel gehen an SK 1.
        for _ in 0..<(result.patients[.sk1] ?? 0) {
            let groundReady = (pool[.rtw] ?? 0) > 0 && (!nefPerSK1 || (pool[.nef] ?? 0) > 0)
            if groundReady {
                _ = take(.rtw)
                if nefPerSK1 { _ = take(.nef) }
            } else if take(.rth) {
                continue
            } else {
                if !take(.rtw) { lack(.rtw) }
                if nefPerSK1, !take(.nef) { lack(.nef) }
            }
        }
        for _ in 0..<(result.patients[.sk2] ?? 0) where !take(.rtw) {
            lack(.rtw)
        }
        for _ in 0..<(result.patients[.sk3] ?? 0) where !take(.ktw) && !take(.rtw) {
            lack(.ktw)
        }
        return result
    }

    private static func poolType(_ type: UnitType) -> UnitType? {
        switch type {
        case .rtw, .nef, .rth: type
        case .ktw, .ktwKatS: .ktw
        default: nil
        }
    }
}

/// Fordert fehlende Einheiten als Platzhalter nach (Schritt 68) und vermerkt es im Tagebuch.
public struct RequestPlaceholders: MissionCommand {
    public let counts: [UnitType: Int]

    public init(_ counts: [UnitType: Int]) {
        self.counts = counts.filter { $0.value > 0 }
    }

    @discardableResult
    public func execute(_ draft: inout MissionDraft) throws -> [MissionUnit] {
        guard !counts.isEmpty else { throw CommandError.invalid("Nichts nachzufordern") }
        var created: [MissionUnit] = []
        for type in ResourceDemand.types + UnitType.allCases.filter({ !ResourceDemand.types.contains($0) }) {
            for _ in 0..<(counts[type] ?? 0) {
                created.append(try AddPlaceholder(type: type).execute(&draft))
            }
        }
        let summary = ResourceDemand.summary(counts)
        _ = try draft.addJournalEntry(text: "Nachforderung an ILS: \(summary)", origin: .automatic)
        draft.log(.unit, "Nachforderung: \(summary)", subject: .mission(draft.missionID))
        return created
    }
}
