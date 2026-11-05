import Foundation
import ELRDDomain

/// Einheiten zur Auswahl beim Patienten.
struct UnitChoice: Identifiable, Equatable {
    let unit: MissionUnit
    /// Diesem Patienten zugeordnet.
    let isAssigned: Bool
    /// Nummern anderer Patienten mit dieser Einheit.
    let otherPatients: [String]

    var id: UnitID { unit.id }
    var isFree: Bool { !isAssigned && otherPatients.isEmpty }

    /// Zugeordnete zuerst, dann freie, dann belegte; innerhalb nach Typ (RTW, NEF, KTW, RTH …).
    static func ordered(units: [MissionUnit], patients: [Patient], for patientID: PatientID) -> [UnitChoice] {
        let active = patients.active.filter { $0.status != .released }
        let choices = units.active.map { unit in
            UnitChoice(
                unit: unit,
                isAssigned: active.contains { $0.id == patientID && $0.unitIDs.contains(unit.id) },
                otherPatients: Patient.sortedByNumber(active.filter { $0.id != patientID && $0.unitIDs.contains(unit.id) })
                    .map(\.number.description)
            )
        }
        return choices.sorted { lhs, rhs in
            let left = (lhs.isAssigned ? 0 : lhs.isFree ? 1 : 2, typeRank(lhs.unit.type), lhs.unit.displayName)
            let right = (rhs.isAssigned ? 0 : rhs.isFree ? 1 : 2, typeRank(rhs.unit.type), rhs.unit.displayName)
            return left < right
        }
    }

    /// Transportmittel zuerst.
    static let typeOrder: [UnitType] = [.rtw, .ktw, .rth, .nef]

    private static func typeRank(_ type: UnitType) -> Int {
        typeOrder.firstIndex(of: type) ?? typeOrder.count
    }

    /// Text auf dem Knopf, z. B. „RTW 71/1“ oder „RTW (Platzhalter 1) · A-4“.
    var label: String {
        otherPatients.isEmpty ? unit.displayName : "\(unit.displayName) · \(otherPatients.joined(separator: ", "))"
    }
}

/// Kliniken zur Auswahl: im Einsatz schon gewählte zuerst, dann die nächsten.
struct HospitalChoice: Identifiable, Equatable {
    let hospital: MasterHospital
    /// Luftlinie in km, falls Einsatzort und Klinik Koordinaten haben.
    let distanceKm: Double?
    /// Anzahl der Patienten in diesem Einsatz mit dieser Zielklinik.
    let usedInMission: Int

    var id: MasterHospitalID { hospital.id }

    var distanceText: String? {
        distanceKm.map { $0 < 10 ? String(format: "%.1f km", $0) : "\(Int($0.rounded())) km" }
    }

    static func ordered(hospitals: [MasterHospital], patients: [Patient], near location: GeoCoordinate?) -> [HospitalChoice] {
        let used = Dictionary(grouping: patients.active.compactMap(\.destination?.masterHospitalID), by: { $0 }).mapValues(\.count)
        let choices = hospitals.map { hospital in
            HospitalChoice(
                hospital: hospital,
                distanceKm: location.flatMap { here in hospital.coordinate.map { here.distance(to: $0) / 1000 } },
                usedInMission: used[hospital.id] ?? 0
            )
        }
        return choices.sorted { lhs, rhs in
            if (lhs.usedInMission > 0) != (rhs.usedInMission > 0) { return lhs.usedInMission > 0 }
            switch (lhs.distanceKm, rhs.distanceKm) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.hospital.name.localizedStandardCompare(rhs.hospital.name) == .orderedAscending
            }
        }
    }

    /// Suche in Name und Ort.
    static func filter(_ choices: [HospitalChoice], search: String) -> [HospitalChoice] {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return choices }
        return choices.filter { choice in
            let text = "\(choice.hospital.name) \(choice.hospital.city)"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
