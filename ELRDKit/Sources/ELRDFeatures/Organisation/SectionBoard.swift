import Foundation
import Observation
import ELRDDomain
import ELRDPersistence
import ELRDStore

/// Patient als kleines Abzeichen (Nummer auf SK-Farbe).
struct PatientBadge: Identifiable, Hashable {
    let id: PatientID
    let number: String
    let triage: Sichtungskategorie
}

/// Einheit mit ihren (nicht entlassenen) Patienten.
struct UnitEntry: Identifiable, Equatable {
    let unit: MissionUnit
    let patients: [PatientBadge]
    var id: UnitID { unit.id }
}

/// Eine Spalte der Abschnittsübersicht: ein Abschnitt oder „ohne Abschnitt“.
struct SectionColumn: Identifiable, Equatable {
    /// `nil`: Einheiten ohne (aktiven) Abschnitt.
    let section: MissionSection?
    let units: [UnitEntry]
    /// Patienten, die direkt im Abschnitt liegen und keine Einheit haben.
    let loosePatients: [PatientBadge]

    var id: String { section?.id.description ?? "ohne-abschnitt" }
    var title: String { section?.name ?? "Ohne Abschnitt" }
    var isInitial: Bool { section?.isInitial == true }

    /// Kurzüberblick „2 RTW · 1 NEF“ (leer ohne Einheiten).
    var typeSummary: String {
        let counts = Dictionary(grouping: units, by: \.unit.type).mapValues(\.count)
        return counts.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\(counts[$0] ?? 0) \($0.shortName)" }
            .joined(separator: " · ")
    }

    /// Spalten in Anzeige-Reihenfolge: „ohne Abschnitt“ (nur falls belegt) zuerst,
    /// dann die Abschnitte nach `sortIndex`.
    static func columns(for state: MissionState) -> [SectionColumn] {
        let sections = state.activeSections
        let sectionIDs = Set(sections.map(\.id))
        let open = Patient.sortedByNumber(state.patients.active.filter { $0.status != .released })
        let units = state.activeUnits.filter { !$0.metadata.isDeleted }
        let activeUnitIDs = Set(units.map(\.id))

        func entries(_ selected: [MissionUnit]) -> [UnitEntry] {
            selected.map { unit in
                UnitEntry(unit: unit, patients: open.filter { $0.unitIDs.contains(unit.id) }.map(Self.badge))
            }
        }

        var result: [SectionColumn] = []
        let homeless = units.filter { $0.sectionID.map { !sectionIDs.contains($0) } ?? true }
        if !homeless.isEmpty {
            result.append(SectionColumn(section: nil, units: entries(homeless), loosePatients: []))
        }
        for section in sections {
            let loose = open.filter { patient in
                patient.sectionID == section.id && !patient.unitIDs.contains(where: activeUnitIDs.contains)
            }
            result.append(SectionColumn(
                section: section,
                units: entries(units.filter { $0.sectionID == section.id }),
                loosePatients: loose.map(Self.badge)
            ))
        }
        return result
    }

    private static func badge(_ patient: Patient) -> PatientBadge {
        PatientBadge(id: patient.id, number: patient.number.description, triage: patient.triage)
    }
}
