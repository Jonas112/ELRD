import SwiftUI
import ELRDDomain

/// Verletzungen erfassen: Region → (Seite) → Diagnose antippen. Mehrere nacheinander.
///
/// Oben stehen die schon erfassten Verletzungen (mit Entfernen), darunter große
/// Knöpfe für Region, Seite und Diagnosen; Freitext legt eine neue Diagnose an.
struct InjuryPickerView: View {
    let catalog: [MasterInjury]
    let injuries: [Injury]
    let onAdd: (Injury) -> Void
    let onRemove: (InjuryID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var region: BodyRegion?
    @State private var side: BodySide?
    @State private var search = ""

    var body: some View {
        let matches = InjurySuggestions.matches(in: catalog, region: region, search: search)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if !injuries.isEmpty { recorded }

                    section("Körperregion") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.s)], spacing: Spacing.s) {
                            ForEach(InjurySuggestions.regionOrder) { candidate in
                                ChoiceChip(candidate.displayName, isSelected: region == candidate, fillsWidth: true) {
                                    region = region == candidate ? nil : candidate
                                    if region?.hasSide != true { side = nil }
                                }
                            }
                        }
                    }

                    if region?.hasSide == true {
                        section("Seite") {
                            HStack(spacing: Spacing.s) {
                                ForEach(BodySide.allCases) { candidate in
                                    ChoiceChip(candidate.displayName, isSelected: side == candidate, fillsWidth: true) {
                                        side = side == candidate ? nil : candidate
                                    }
                                }
                            }
                        }
                    }

                    section(region.map { "Diagnose – \($0.displayName)" } ?? "Diagnose") {
                        HStack(spacing: Spacing.s) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Suchen oder neue Diagnose eingeben", text: $search)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit { if InjurySuggestions.offersCustom(search, in: matches) { addCustom() } }
                        }
                        .inputBox()

                        if InjurySuggestions.offersCustom(search, in: matches) {
                            Button(action: addCustom) {
                                Label("„\(search.trimmingCharacters(in: .whitespaces))“ als neue Diagnose erfassen", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable, alignment: .leading)
                            }
                        }

                        FlowLayout(spacing: Spacing.s) {
                            ForEach(matches) { master in
                                ChoiceChip(label(for: master), isSelected: false, minHeight: 52) {
                                    add(master)
                                }
                            }
                        }
                        if matches.isEmpty && search.isEmpty {
                            Text("Für diese Region gibt es keine Diagnosen in den Stammdaten.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.canvas)
            .navigationTitle("Verletzungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }

    private var recorded: some View {
        section("Erfasst") {
            VStack(spacing: Spacing.s) {
                ForEach(injuries) { injury in
                    InjuryRow(injury: injury) { onRemove(injury.id) }
                }
            }
        }
    }

    /// Ohne gewählte Region die Region mit anzeigen, damit „Fraktur“ eindeutig bleibt.
    private func label(for master: MasterInjury) -> String {
        guard region == nil, let masterRegion = master.region else { return master.diagnosis }
        return "\(master.diagnosis) · \(masterRegion.displayName)"
    }

    private func add(_ master: MasterInjury) {
        onAdd(InjurySuggestions.injury(from: master, text: "", region: region, side: side))
    }

    private func addCustom() {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAdd(InjurySuggestions.injury(from: nil, text: text, region: region, side: side))
        search = ""
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Verletzung mit Entfernen-Knopf.
struct InjuryRow: View {
    let injury: Injury
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(injury.displayText)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                        .background(Surface.card, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(injury.displayText) entfernen")
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .frame(minHeight: TouchTarget.comfortable)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
