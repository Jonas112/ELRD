import SwiftUI
import ELRDDomain
import ELRDStore

/// Platzhalter durch das tatsächliche Fahrzeug ersetzen: Funkrufname eintippen
/// oder aus den unbenutzten Stammdaten wählen (vorgefiltert auf den Typ, wie ELRDRG).
struct ReplacePlaceholderSheet: View {
    let store: MissionStore
    let masterData: MasterDataEditor?
    let placeholder: MissionUnit

    @Environment(\.dismiss) private var dismiss
    @State private var filter: UnitFilter
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    init(store: MissionStore, masterData: MasterDataEditor?, placeholder: MissionUnit) {
        self.store = store
        self.masterData = masterData
        self.placeholder = placeholder
        _filter = State(initialValue: UnitFilter(type: UnitTypeFilter.matching(placeholder.type)))
    }

    private var typed: String { filter.search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let available = masterData?.unusedUnits(in: store.state.units) ?? []
        let counts = UnitFilter.counts(available, search: filter.search, type: \.type) { "\($0.callsign) \($0.typeDisplayName)" }
        let matching = available.filter { filter.matches($0) }
        let exactMatch = available.contains { MasterDataMatching.key($0.callsign) == MasterDataMatching.key(typed) }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "questionmark.square.dashed").font(.title2).foregroundStyle(.secondary)
                        Text(placeholder.displayName).font(.title3.weight(.bold))
                    }
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Funkrufname eintippen oder suchen", text: $filter.search)
                            .font(.title3)
                            .focused($searchFocused)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { if !typed.isEmpty, !exactMatch { replaceTyped() } }
                    }
                    .inputBox()
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if !typed.isEmpty, !exactMatch {
                        Button(action: replaceTyped) {
                            HStack(spacing: Spacing.m) {
                                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("„\(typed)“ übernehmen").font(.headline).foregroundStyle(.white).lineLimit(2)
                                    Text("als \(placeholder.type.shortName), nicht aus den Stammdaten")
                                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: TouchTarget.large)
                            .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if !available.isEmpty {
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
                        if matching.isEmpty {
                            Text(filter.type == .all ? "Keine Einheit aus den Stammdaten passt." : "Keine passende \(filter.type.title)-Einheit. „Alle“ zeigt jeden Typ.")
                                .foregroundStyle(.secondary)
                        }
                        LazyVStack(spacing: Spacing.s) {
                            ForEach(matching) { unit in
                                Button { replace(with: .master(unit)) } label: { MasterUnitRow(unit: unit) }
                                    .buttonStyle(.plain)
                            }
                        }
                    } else if let masterData, masterData.units.isEmpty {
                        LoadRegionHint(masterData: masterData)
                    } else if typed.isEmpty {
                        Text("Funkrufname des Fahrzeugs eintippen.").foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.canvas)
            .navigationTitle("Fahrzeug eintragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .onAppear { if available.isEmpty { searchFocused = true } }
        }
    }

    private func replaceTyped() {
        guard !typed.isEmpty else { return }
        replace(with: .temporary(callsign: typed, type: placeholder.type))
    }

    private func replace(with replacement: ReplacePlaceholder.Replacement) {
        do {
            _ = try store.perform(ReplacePlaceholder(unitID: placeholder.id, with: replacement))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
