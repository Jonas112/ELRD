import Foundation
import ELRDDomain
import ELRDStore

/// Kennzahlen für die Lage-Übersicht (Schritt 37), aus dem Einsatzstand berechnet.
struct SituationDashboard: Equatable {
    /// Patienten je Zielklinik.
    struct HospitalLoad: Identifiable, Equatable {
        let name: String
        let byTriage: [Sichtungskategorie: Int]
        var id: String { name }
        var total: Int { byTriage.values.reduce(0, +) }
    }

    let triageCounts: [Sichtungskategorie: Int]
    let patientTotal: Int
    /// Freie RTW, KTW, KTW-KatS, RTH.
    let freeTransport: Int
    /// Transportmittel bei Patienten, die noch nicht entlassen sind.
    let busyTransport: Int
    /// Platzhalter, deren Fahrzeug noch unbekannt ist.
    let placeholders: Int
    /// Alle Einheiten im Einsatz.
    let unitTotal: Int
    /// Meiste Patienten zuerst.
    let hospitals: [HospitalLoad]

    init(state: MissionState) {
        let patients = state.patients.active
        patientTotal = patients.count
        triageCounts = Dictionary(grouping: patients, by: \.triage).mapValues(\.count)

        let units = state.units.active
        unitTotal = units.count
        placeholders = units.filter(\.isPlaceholder).count
        let busyIDs = Set(patients.filter { $0.status != .released }.flatMap(\.unitIDs))
        let transport = units.filter { $0.type.transportsPatients }
        busyTransport = transport.filter { busyIDs.contains($0.id) }.count
        freeTransport = transport.count - busyTransport

        let withDestination = patients.filter { $0.destination != nil }
        let grouped = Dictionary(grouping: withDestination) { $0.destination?.name ?? "" }
        hospitals = grouped
            .map { name, list in HospitalLoad(name: name, byTriage: Dictionary(grouping: list, by: \.triage).mapValues(\.count)) }
            .sorted { lhs, rhs in
                lhs.total != rhs.total ? lhs.total > rhs.total : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
