import SwiftUI
import ELRDDomain
import ELRDStore

// MARK: - Globale Suche (Schritt 134)

/// Ein Treffer der globalen Suche.
struct GlobalSearchResult: Identifiable, Equatable {
    enum Kind: Equatable {
        case patient(PatientID)
        case unit(UnitID)
        case section(SectionID)
        case area(WorkspaceSection)
        case messages
        case report
        case newPatient(Sichtungskategorie)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let systemImage: String
    var triage: Sichtungskategorie?
}

/// Sucht in Patienten (Nummer, Name, ILS-Nummer, Anhängekarte, Merkmale), Einheiten,
/// Abschnitten und Aktionen. Groß-/Kleinschreibung und Akzente egal.
enum GlobalSearch {
    static let maxPerGroup = 8

    static func results(for query: String, in state: MissionState, canAddPatients: Bool) -> [GlobalSearchResult] {
        let needle = normalize(query)
        let actions = actionResults(canAddPatients: canAddPatients)
        guard !needle.isEmpty else { return actions }
        func matches(_ fields: [String?]) -> Bool {
            fields.contains { $0.map { normalize($0).contains(needle) } ?? false }
        }
        let patients = Patient.sortedByNumber(state.patients).filter { patient in
            matches(["\(patient.number)", patient.firstName, patient.lastName, patient.dispatchPatientNumber,
                     patient.tagNumber, patient.identifyingFeatures, patient.triage.shortName])
        }.prefix(maxPerGroup).map { patient in
            GlobalSearchResult(
                id: "patient-\(patient.id.rawValue.uuidString)", kind: .patient(patient.id),
                title: patient.displayName,
                detail: [patient.triage.shortName, patient.status.displayName, patient.identifyingFeatures ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: "person.fill", triage: patient.triage
            )
        }
        let sectionNames = Dictionary(uniqueKeysWithValues: state.sections.active.map { ($0.id, $0.name) })
        let units = MissionUnit.sorted(state.units.active).filter { unit in
            matches([unit.displayName, unit.typeDisplayName])
        }.prefix(maxPerGroup).map { unit in
            GlobalSearchResult(
                id: "unit-\(unit.id.rawValue.uuidString)", kind: .unit(unit.id),
                title: unit.displayName,
                detail: [unit.typeDisplayName, unit.sectionID.flatMap { sectionNames[$0] } ?? "ohne Abschnitt"].joined(separator: " · "),
                systemImage: "box.truck.fill"
            )
        }
        let sections = MissionSection.sorted(state.sections.active).filter { matches([$0.name, $0.leaderName, $0.leaderCallsign]) }
            .prefix(maxPerGroup).map { section in
                GlobalSearchResult(
                    id: "section-\(section.id.rawValue.uuidString)", kind: .section(section.id),
                    title: section.name, detail: section.leaderName.map { "Leitung \($0)" } ?? "Abschnitt",
                    systemImage: "square.stack.3d.up.fill"
                )
            }
        let matchingActions = actions.filter { matches([$0.title, $0.detail]) }
        return Array(patients) + Array(units) + Array(sections) + matchingActions
    }

    static func actionResults(canAddPatients: Bool) -> [GlobalSearchResult] {
        var results = WorkspaceSection.allCases.map { area in
            GlobalSearchResult(id: "area-\(area.rawValue)", kind: .area(area), title: area.title, detail: "Bereich öffnen", systemImage: area.systemImage)
        }
        results.append(GlobalSearchResult(id: "messages", kind: .messages, title: "Nachrichten", detail: "Meldungen lesen und senden", systemImage: "bell"))
        results.append(GlobalSearchResult(id: "report", kind: .report, title: "Bericht", detail: "PDF erstellen, drucken, senden", systemImage: "doc.richtext"))
        if canAddPatients {
            for triage in SituationBar.counterOrder {
                results.append(GlobalSearchResult(id: "new-\(triage.rawValue)", kind: .newPatient(triage), title: "Neuer Patient \(triage.shortName)",
                                                   detail: "Patient anlegen", systemImage: "plus.circle.fill", triage: triage))
            }
        }
        return results
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Suchblatt: ein Feld, Treffer gruppiert; Eingabetaste öffnet den ersten Treffer.
struct GlobalSearchSheet: View {
    let store: MissionStore
    let canAddPatients: Bool
    let onSelect: (GlobalSearchResult.Kind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let results = GlobalSearch.results(for: query, in: store.state, canAddPatients: canAddPatients)
        NavigationStack {
            List {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(results) { result in
                    Button { choose(result.kind) } label: { row(result) }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Patient, Einheit, Abschnitt oder Aktion", text: $query)
                        .font(.title3)
                        .focused($focused)
                        .submitLabel(.go)
                        .autocorrectionDisabled()
                        .onSubmit { if let first = results.first { choose(first.kind) } }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("Suche leeren")
                    }
                }
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: TouchTarget.comfortable)
                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(Spacing.l)
                .background(.bar)
            }
            .navigationTitle("Suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .onAppear { focused = true }
        }
    }

    private func row(_ result: GlobalSearchResult) -> some View {
        HStack(spacing: Spacing.m) {
            Group {
                if let triage = result.triage {
                    Text(triage.shortName)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Color.onTriage(triage))
                        .frame(width: 48, height: 32)
                        .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                } else {
                    Image(systemName: result.systemImage)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 32)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(result.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: TouchTarget.comfortable)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func choose(_ kind: GlobalSearchResult.Kind) {
        dismiss()
        onSelect(kind)
    }
}
