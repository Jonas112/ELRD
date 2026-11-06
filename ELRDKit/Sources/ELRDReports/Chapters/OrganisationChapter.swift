import Foundation
import ELRDDomain

/// Kapitel „Organisation“ (Schritt 41): Abschnitte mit ihren Einheiten und den
/// zugeordneten Patienten; Patienten ohne Einheit je Abschnitt.
enum OrganisationChapter {
    static func blocks(_ input: ReportInput, options: ReportChapterOptions) -> [ReportBlock] {
        let units = MissionUnit.sorted(input.units.filter { options.includesPlaceholders || !$0.isPlaceholder })
        let sections = MissionSection.sorted(input.sections)
        var blocks: [ReportBlock] = [.heading(ReportChapter.Kind.organisation.displayName, level: 1)]
        let placeholderCount = units.filter(\.isPlaceholder).count
        var summary = "\(units.count == 1 ? "1 Einheit" : "\(units.count) Einheiten") in \(sections.count == 1 ? "1 Abschnitt" : "\(sections.count) Abschnitten")"
        if placeholderCount > 0 { summary += ", davon \(placeholderCount) Platzhalter ohne bekanntes Fahrzeug" }
        blocks.append(.paragraph(summary + ".", style: .muted))

        if units.isEmpty && sections.isEmpty {
            blocks.append(.paragraph("Keine Einheiten erfasst."))
            return blocks
        }

        var groups: [(title: String, sectionID: SectionID?)] = sections.map {
            ($0.isInitial ? "\($0.name) (Initialabschnitt)" : $0.name, $0.id)
        }
        let knownIDs = Set(sections.map(\.id))
        if units.contains(where: { $0.sectionID == nil || !knownIDs.contains($0.sectionID!) }) {
            groups.append(("Ohne Abschnitt", nil))
        }
        for group in groups {
            let members = units.filter { unit in
                guard let groupID = group.sectionID else { return unit.sectionID == nil || !knownIDs.contains(unit.sectionID!) }
                return unit.sectionID == groupID
            }
            let loose = Patient.sortedByNumber(input.patients.filter { patient in
                patient.sectionID == group.sectionID && group.sectionID != nil
                    && !patient.unitIDs.contains { id in input.units.contains { $0.id == id } }
            })
            blocks.append(.heading(group.title, level: 2))
            if members.isEmpty {
                blocks.append(.paragraph("Keine Einheiten.", style: .muted))
            } else {
                blocks.append(.table(table(members, patients: input.patients, options: options)))
            }
            if !loose.isEmpty {
                blocks.append(.paragraph("Patienten ohne Einheit: " + loose.map(ReportFormat.patientLabel).joined(separator: ", "), style: .small))
            }
        }
        return blocks
    }

    static func table(_ units: [MissionUnit], patients: [Patient], options: ReportChapterOptions) -> ReportTable {
        var columns = [
            ReportTable.Column("Typ", width: .fixed(58)),
            ReportTable.Column("Funkrufname", width: .flexible(2)),
            ReportTable.Column("Besatzung", width: .fixed(62), alignsRight: true),
        ]
        if options.showsPatientAssignment { columns.append(ReportTable.Column("Patienten", width: .flexible(1.6))) }
        let rows: [[ReportTable.Cell]] = units.map { unit in
            var row = [
                ReportTable.Cell(unit.typeDisplayName, isBold: true),
                ReportTable.Cell(unit.displayName + (unit.isPlaceholder ? " – Fahrzeug unbekannt" : "") + (unit.isTemporary ? " (temporär)" : "")),
                ReportTable.Cell(unit.crewCount.map { "\($0)" } ?? "–"),
            ]
            if options.showsPatientAssignment {
                let assigned = Patient.sortedByNumber(patients.filter { $0.unitIDs.contains(unit.id) })
                let text = assigned.map { patient in
                    ReportFormat.patientLabel(patient) + (patient.status == .released ? " entlassen" : "")
                }.joined(separator: ", ")
                row.append(ReportTable.Cell(text.isEmpty ? "–" : text))
            }
            return row
        }
        return ReportTable(columns: columns, rows: rows)
    }
}
