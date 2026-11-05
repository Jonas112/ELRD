import SwiftUI
import ELRDDomain
import ELRDStore

/// Einheiten hinzufügen: oben der Zielabschnitt, darunter Stammdaten (Tipp =
/// hinzugefügt, mehrere nacheinander) oder eine neue, temporäre Einheit.
struct AddUnitSheet: View {
    enum Source: Hashable { case masterData, temporary }

    let store: MissionStore
    let masterData: MasterDataEditor?

    @Environment(\.dismiss) private var dismiss
    @State private var targetID: SectionID?
    @State private var source: Source = .masterData
    @State private var filter = UnitFilter()
    @State private var callsign = ""
    @State private var type: UnitType = .rtw
    @State private var saveToMasterData = false
    @State private var lastAdded: String?
    @State private var errorMessage: String?

    init(store: MissionStore, masterData: MasterDataEditor?) {
        self.store = store
        self.masterData = masterData
        _targetID = State(initialValue: MissionSection.initialSection(in: store.state.sections)?.id)
        _source = State(initialValue: (masterData?.units.isEmpty ?? true) ? .temporary : .masterData)
    }

    private var trimmedCallsign: String { callsign.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    targetPicker
                    SegmentedChoice(
                        options: [(Source.masterData, "Aus Stammdaten"), (.temporary, "Neue Einheit")],
                        selection: $source
                    )
                    if let lastAdded {
                        Label(lastAdded, systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    switch source {
                    case .masterData: masterList
                    case .temporary: temporaryForm
                    }
                }
                .padding(Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.canvas)
            .navigationTitle("Einheit hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }

    // MARK: Zielabschnitt

    private var targetPicker: some View {
        let sections = store.state.activeSections
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Abschnitt").font(.headline).foregroundStyle(.secondary)
            if sections.isEmpty {
                Text("Noch keine Abschnitte – die Einheit steht „ohne Abschnitt“.")
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: Spacing.s) {
                    ForEach(sections) { section in
                        ChoiceChip(section.isInitial ? "\(section.name) · Initial" : section.name,
                                   isSelected: targetID == section.id, minHeight: 52) {
                            targetID = section.id
                        }
                    }
                    ChoiceChip("Ohne Abschnitt", isSelected: targetID == nil, minHeight: 52) { targetID = nil }
                }
            }
        }
    }

    // MARK: Stammdaten

    private var masterList: some View {
        let available = masterData?.unusedUnits(in: store.state.units) ?? []
        let counts = UnitFilter.counts(available, search: filter.search, type: \.type) { "\($0.callsign) \($0.typeDisplayName)" }
        let matching = available.filter { filter.matches($0) }
        return VStack(alignment: .leading, spacing: Spacing.m) {
            UnitSearchField(text: $filter.search)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(UnitTypeFilter.allCases) { type in
                        if type == .all || (counts[type] ?? 0) > 0 || filter.type == type {
                            FilterPill(title: "\(type.title) \(counts[type] ?? 0)", isSelected: filter.type == type) {
                                filter.type = type
                            }
                        }
                    }
                }
            }
            if available.isEmpty {
                Text((masterData?.units.isEmpty ?? true)
                     ? "Keine Einheiten in den Stammdaten. Unter „Neue Einheit“ anlegen; Regionen lassen sich unter Einstellungen → Stammdaten importieren (Schritt 48)."
                     : "Alle Einheiten aus den Stammdaten sind schon im Einsatz.")
                    .foregroundStyle(.secondary)
            } else if matching.isEmpty {
                Text("Keine Einheit passt. Unter „Neue Einheit“ lässt sie sich anlegen.")
                    .foregroundStyle(.secondary)
            }
            LazyVStack(spacing: Spacing.s) {
                ForEach(matching) { unit in
                    Button { add(unit) } label: { MasterUnitRow(unit: unit) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Temporär

    private var temporaryForm: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Funkrufname").font(.headline).foregroundStyle(.secondary)
            TextField("z. B. Rotkreuz Musterstadt 71/1", text: $callsign)
                .font(.title3)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(addTemporary)
                .inputBox()
            Text("Typ").font(.headline).foregroundStyle(.secondary)
            FlowLayout(spacing: Spacing.s) {
                ForEach(UnitType.allCases) { candidate in
                    ChoiceChip(candidate.shortName, isSelected: type == candidate, minHeight: 52) { type = candidate }
                        .accessibilityLabel(candidate.displayName)
                }
            }
            if masterData != nil, !trimmedCallsign.isEmpty, masterData?.containsUnit(trimmedCallsign) == false {
                Toggle(isOn: $saveToMasterData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In Stammdaten übernehmen").font(.headline)
                        Text("Steht bei künftigen Einsätzen zur Auswahl.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            }
            Button(action: addTemporary) {
                Text("Einheit anlegen")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(trimmedCallsign.isEmpty ? Color.secondary : Color.white)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                    .background(trimmedCallsign.isEmpty ? Surface.elevated : ActionFill.primary,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(trimmedCallsign.isEmpty)
        }
    }

    // MARK: Aktionen

    private var targetName: String {
        targetID.flatMap { id in store.state.activeSections.first { $0.id == id }?.name } ?? "ohne Abschnitt"
    }

    private func add(_ unit: MasterUnit) {
        do {
            _ = try store.perform(AddMasterUnits([unit], sectionID: targetID))
            errorMessage = nil
            lastAdded = "\(unit.callsign) → \(targetName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTemporary() {
        guard !trimmedCallsign.isEmpty else { return }
        do {
            let unit = try store.perform(AddTemporaryUnit(callsign: trimmedCallsign, type: type, sectionID: targetID))
            if saveToMasterData { try masterData?.saveUnit(callsign: trimmedCallsign, type: type) }
            errorMessage = nil
            lastAdded = "\(unit.displayName) → \(targetName)"
            callsign = ""
            saveToMasterData = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Zeile einer Stammdaten-Einheit.
struct MasterUnitRow: View {
    let unit: MasterUnit

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(unit.typeDisplayName)
                .font(.subheadline.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 60, height: 36)
                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(unit.callsign)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(ActionFill.primary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 60)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unit.typeDisplayName) \(unit.callsign) hinzufügen")
    }
}
