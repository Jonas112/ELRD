import Foundation
import ELRDDomain

/// Kapitel „Patienten“ (Schritt 42): Übersichtstabelle oder Einzelbogen je Patient
/// (eine Seite, z. B. zur Übergabe). Sortiert wie in ELRDRG nach SK, dann Nummer.
enum PatientsChapter {
    static func blocks(_ input: ReportInput, options: ReportChapterOptions, theme: ReportTheme) -> [ReportBlock] {
        let patients = selected(input.patients, options: options)
        var blocks: [ReportBlock] = [.heading(ReportChapter.Kind.patients.displayName, level: 1)]
        if let destination = options.destinationFilter {
            blocks.append(.paragraph("Nur Patienten für: \(destination)", style: .muted))
        }
        if !options.triageFilter.isEmpty {
            let names = Sichtungskategorie.allCases.filter { options.triageFilter.contains($0) }.map(\.shortName)
            blocks.append(.paragraph("Auswahl: \(names.joined(separator: ", "))", style: .muted))
        }
        guard !patients.isEmpty else {
            blocks.append(.paragraph("Keine Patienten.", style: .muted))
            return blocks
        }
        blocks.append(.metrics(MissionInfoChapter.triageMetrics(patients, theme: theme)))
        if options.usesPatientSheets {
            for (index, patient) in patients.enumerated() {
                if index > 0 { blocks.append(.pageBreak) }
                blocks.append(contentsOf: sheet(patient, input: input, options: options, theme: theme))
            }
        } else {
            blocks.append(.table(table(patients, input: input, options: options, theme: theme)))
        }
        return blocks
    }

    static func selected(_ patients: [Patient], options: ReportChapterOptions) -> [Patient] {
        var filtered = options.triageFilter.isEmpty ? patients : patients.filter { options.triageFilter.contains($0.triage) }
        if let destination = options.destinationFilter {
            filtered = filtered.filter { ReportDestination.matches($0, filter: destination) }
        }
        return Patient.sortedByTriage(filtered)
    }

    static func table(_ patients: [Patient], input: ReportInput, options: ReportChapterOptions, theme: ReportTheme) -> ReportTable {
        var columns = [
            ReportTable.Column("Nr.", width: .fixed(38)),
            ReportTable.Column("SK", width: .fixed(36)),
        ]
        if options.showsPatientNames { columns.append(ReportTable.Column("Name", width: .flexible(1.3))) }
        columns += [
            ReportTable.Column("Alter", width: .fixed(46)),
            ReportTable.Column("Befund", width: .flexible(2)),
            ReportTable.Column("Einheit", width: .flexible(1.1)),
            ReportTable.Column("Ziel", width: .flexible(1.3)),
            ReportTable.Column("Stand", width: .fixed(70)),
        ]
        let rows: [[ReportTable.Cell]] = patients.map { patient in
            var row = [
                ReportTable.Cell(patient.number.description, isBold: true),
                triageCell(patient.triage, theme: theme),
            ]
            if options.showsPatientNames { row.append(ReportTable.Cell(patient.fullName.isEmpty ? (patient.identifyingFeatures ?? "–") : patient.fullName)) }
            row += [
                ReportTable.Cell(ageText(patient, at: input.mission.startedAt)),
                ReportTable.Cell(findings(patient).joined(separator: "; ").ifEmpty("–")),
                ReportTable.Cell(unitNames(patient, input: input).ifEmpty("–")),
                ReportTable.Cell(destinationText(patient).ifEmpty("–")),
                ReportTable.Cell(statusText(patient)),
            ]
            return row
        }
        return ReportTable(columns: columns, rows: rows)
    }

    /// Einzelbogen: alle Angaben eines Patienten.
    static func sheet(_ patient: Patient, input: ReportInput, options: ReportChapterOptions, theme: ReportTheme) -> [ReportBlock] {
        var pairs: [ReportKeyValue] = []
        if options.showsPatientNames {
            pairs.append(ReportKeyValue("Name", patient.fullName))
        }
        if let features = patient.identifyingFeatures, !features.isEmpty {
            pairs.append(ReportKeyValue("Erkennungsmerkmale", features))
        }
        pairs.append(ReportKeyValue("Alter, Geschlecht", [ageText(patient, at: input.mission.startedAt), patient.gender.displayName].joined(separator: ", ")))
        if let dispatch = patient.dispatchPatientNumber, !dispatch.isEmpty {
            pairs.append(ReportKeyValue("Patientennummer ILS", dispatch))
        }
        pairs.append(ReportKeyValue("Befund", findings(patient).joined(separator: "\n")))
        let code = patient.allocationCode(at: input.mission.startedAt)
        if patient.rmiCode != nil || patient.treatmentPriority != .keineDringlichkeit {
            pairs.append(ReportKeyValue("IVENA (PZC)", "\(code) – \(patient.treatmentPriority.displayName)"))
        }
        if let abcd = patient.abcd, !abcd.isEmpty {
            pairs.append(ReportKeyValue("ABCD", abcd.summary))
        }
        if let section = input.sections.first(where: { $0.id == patient.sectionID }) {
            pairs.append(ReportKeyValue("Abschnitt", section.name))
        }
        pairs.append(ReportKeyValue("Einheiten", unitNames(patient, input: input)))
        pairs.append(ReportKeyValue("Zielklinik", destinationText(patient)))
        pairs.append(ReportKeyValue("Stand", statusText(patient, long: true)))
        if !patient.notes.isEmpty {
            pairs.append(ReportKeyValue("Notizen", patient.notes))
        }
        let title = "Patient \(patient.number)"
        return [
            .heading(title, level: 2),
            .metrics([ReportMetric(
                value: patient.triage.shortName,
                label: patient.triage.displayName,
                fill: theme.showsTriageColors ? patient.triage.color : nil,
                textColor: theme.showsTriageColors ? patient.triage.color.contrastingTextColor : nil
            )]),
            .keyValues(pairs),
        ]
    }

    // MARK: Texte

    static func triageCell(_ triage: Sichtungskategorie, theme: ReportTheme) -> ReportTable.Cell {
        ReportTable.Cell(
            triage.shortName,
            fill: theme.showsTriageColors ? triage.color : nil,
            textColor: theme.showsTriageColors ? triage.color.contrastingTextColor : nil,
            isBold: true
        )
    }

    static func ageText(_ patient: Patient, at date: Date) -> String {
        let age = patient.age(at: date).map { "\($0) J." } ?? (patient.isChild ? "Kind" : "–")
        let gender: String
        switch patient.gender {
        case .maennlich: gender = " m"
        case .weiblich: gender = " w"
        default: gender = ""
        }
        return age + gender
    }

    static func findings(_ patient: Patient) -> [String] {
        patient.medicalSummaryLines
    }

    static func unitNames(_ patient: Patient, input: ReportInput) -> String {
        if case let .released(_, handledBy)? = patient.outcome, patient.unitIDs.isEmpty {
            return handledBy.joined(separator: ", ")
        }
        return patient.unitIDs.compactMap { id in input.units.first { $0.id == id }?.displayName }.joined(separator: ", ")
    }

    static func destinationText(_ patient: Patient) -> String {
        guard let destination = patient.destination else { return "" }
        let state = patient.registrationState == .unklar ? "" : " (\(patient.registrationState.displayName))"
        return destination.name + state
    }

    static func statusText(_ patient: Patient, long: Bool = false) -> String {
        switch patient.outcome {
        case let .transported(startedAt)?:
            return (long ? "Transport begonnen " : "Transport ") + ReportFormat.time(startedAt)
        case let .released(at, _)?:
            return (long ? "Vor Ort entlassen " : "entlassen ") + ReportFormat.time(at)
        case nil:
            return patient.status.displayName
        }
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
