import SwiftUI
import ELRDDomain

/// Verletzungen erfassen: Körperteil in der Grafik antippen (Region und Seite
/// in einem Tipp) → Diagnose antippen. Mehrere nacheinander.
///
/// Oben bzw. rechts stehen die schon erfassten Verletzungen (mit Entfernen),
/// darunter die Diagnosen; Freitext legt eine neue Diagnose an.
struct InjuryPickerView: View {
    let catalog: [MasterInjury]
    let injuries: [Injury]
    let onAdd: (Injury) -> Void
    let onRemove: (InjuryID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var spot: BodySpot?
    @State private var search = ""

    init(catalog: [MasterInjury], injuries: [Injury], initialSpot: BodySpot? = nil,
         onAdd: @escaping (Injury) -> Void, onRemove: @escaping (InjuryID) -> Void) {
        self.catalog = catalog
        self.injuries = injuries
        self.onAdd = onAdd
        self.onRemove = onRemove
        _spot = State(initialValue: initialSpot)
    }

    private var region: BodyRegion? { spot?.region }
    private var side: BodySide? { spot?.side }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let isWide = proxy.size.width >= 640
                ScrollView {
                    Group {
                        if isWide {
                            HStack(alignment: .top, spacing: Spacing.xl) {
                                diagram.frame(width: 250, height: 440)
                                details
                            }
                        } else {
                            VStack(alignment: .leading, spacing: Spacing.xl) {
                                diagram.frame(height: 320).frame(maxWidth: .infinity)
                                details
                            }
                        }
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
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

    private var diagram: some View {
        VStack(spacing: Spacing.s) {
            BodyDiagramView(selection: spot, counts: BodyPart.counts(for: injuries)) { tapped in
                spot = spot == tapped ? nil : tapped
            }
            Text(spot?.title ?? "Körperteil antippen")
                .font(.headline)
                .foregroundStyle(spot == nil ? .secondary : .primary)
        }
    }

    private var details: some View {
        let matches = InjurySuggestions.matches(in: catalog, region: region, search: search)
        return VStack(alignment: .leading, spacing: Spacing.xl) {
            if !injuries.isEmpty { recorded }

            section(spot.map { "Diagnose – \($0.title)" } ?? "Diagnose – alle Regionen") {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
