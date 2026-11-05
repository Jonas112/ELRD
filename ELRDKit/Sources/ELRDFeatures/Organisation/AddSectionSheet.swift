import SwiftUI
import ELRDDomain

/// Abschnitt anlegen: Vorlage antippen oder Namen eingeben.
struct AddSectionSheet: View {
    struct Request: Equatable {
        var name: String
        var masterSectionID: MasterSectionID?
        var makeInitial: Bool
        var saveAsTemplate: Bool
    }

    let existing: [MissionSection]
    let templates: MasterDataEditor?
    let onAdd: (Request) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var makeInitial: Bool
    @State private var saveAsTemplate = false
    @FocusState private var nameFocused: Bool

    init(existing: [MissionSection], templates: MasterDataEditor?, onAdd: @escaping (Request) -> Void) {
        self.existing = existing
        self.templates = templates
        self.onAdd = onAdd
        // Ohne Initialabschnitt wird der neue automatisch einer (E68).
        _makeInitial = State(initialValue: MissionSection.initialSection(in: existing) == nil)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool {
        let key = MasterDataMatching.key(trimmed)
        return existing.active.contains { MasterDataMatching.key($0.name) == key }
    }

    var body: some View {
        let suggestions = templates?.unused(in: existing) ?? []
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            Text("Aus den Stammdaten").font(.headline).foregroundStyle(.secondary)
                            FlowLayout(spacing: Spacing.s) {
                                ForEach(suggestions) { template in
                                    ChoiceChip(template.name, isSelected: false, minHeight: 56) {
                                        add(Request(name: template.name, masterSectionID: template.id,
                                                    makeInitial: makeInitial || template.isInitial, saveAsTemplate: false))
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text(suggestions.isEmpty ? "Name" : "Oder neuer Abschnitt").font(.headline).foregroundStyle(.secondary)
                        TextField("z. B. Patientenablage", text: $name)
                            .font(.title3)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(addTyped)
                            .inputBox()
                        if isDuplicate {
                            Label("Einen Abschnitt mit diesem Namen gibt es schon.", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        Toggle(isOn: $makeInitial) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Initialabschnitt").font(.headline)
                                Text("Neue Einheiten kommen hierher.").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: TouchTarget.comfortable)
                        if templates != nil, !trimmed.isEmpty, templates?.contains(trimmed) == false {
                            Toggle(isOn: $saveAsTemplate) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("In Stammdaten übernehmen").font(.headline)
                                    Text("Steht bei künftigen Einsätzen als Vorschlag bereit.").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: TouchTarget.comfortable)
                        }
                        Button(action: addTyped) {
                            Text("Abschnitt anlegen")
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.white)
                                .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                                .background(trimmed.isEmpty ? Surface.elevated : ActionFill.primary,
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(trimmed.isEmpty)
                    }
                }
                .padding(Spacing.xl)
            }
            .background(Surface.canvas)
            .navigationTitle("Neuer Abschnitt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .onAppear { if suggestions.isEmpty { nameFocused = true } }
        }
    }

    private func addTyped() {
        guard !trimmed.isEmpty else { return }
        add(Request(name: trimmed, masterSectionID: nil, makeInitial: makeInitial, saveAsTemplate: saveAsTemplate))
    }

    private func add(_ request: Request) {
        onAdd(request)
        dismiss()
    }
}
