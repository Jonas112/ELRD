import SwiftUI
import ELRDDomain

/// „Neuer Einsatz“: nur Stichwort, Einsatzart, Ort und optional Meldebild/ILS-Nummer.
/// Beginn ist „jetzt“, Einsatzleiter ist der angemeldete Benutzer.
struct NewMissionView: View {
    let commanderName: String
    let start: (NewMissionForm) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form = NewMissionForm()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    stichwortSection
                    typeSection
                    locationSection
                    detailsSection
                    Text("Beginn ist jetzt. Einsatzleiter: \(commanderName). Alles Weitere lässt sich im Einsatz ergänzen.")
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.canvas)
            .safeAreaInset(edge: .bottom) { startBar }
            .navigationTitle("Neuer Einsatz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .frame(minHeight: TouchTarget.minimum)
                }
            }
        }
        // Eingaben nicht durch versehentliches Wischen verlieren.
        .interactiveDismissDisabled(form != NewMissionForm())
    }

    // MARK: Abschnitte

    private var stichwortSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Alarmstichwort")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: 3), spacing: Spacing.m) {
                ForEach(Alarmstichwort.allCases) { stichwort in
                    ChoiceChip(stichwort.rawValue, isSelected: form.alarmstichwort == stichwort, minHeight: TouchTarget.large, fillsWidth: true) {
                        form.alarmstichwort = form.alarmstichwort == stichwort ? nil : stichwort
                    }
                }
                ChoiceChip("Ohne", isSelected: form.alarmstichwort == nil, minHeight: TouchTarget.large, fillsWidth: true) {
                    form.alarmstichwort = nil
                }
            }
            Text(stichwortHint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var stichwortHint: String {
        guard let stichwort = form.alarmstichwort else { return "Ohne Stichwort werden keine Platzhalter angelegt." }
        return "Legt \(stichwort.summary) als Platzhalter an – später durch echte Fahrzeuge ersetzen."
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Einsatzart")
            FlowLayout(spacing: Spacing.s) {
                ForEach(NewMissionForm.typeOrder, id: \.self) { type in
                    ChoiceChip(type.chipLabel, isSelected: form.type == type) {
                        form.type = form.type == type ? nil : type
                    }
                }
            }
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Einsatzort")
            inputField("z. B. B 19, Höhe Ausfahrt Musterstadt", text: $form.location)
                .textContentType(.fullStreetAddress)
        }
    }

    private var detailsSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.l) {
                reasonField.frame(minWidth: 260)
                dispatchField.frame(minWidth: 260)
            }
            VStack(alignment: .leading, spacing: Spacing.xl) {
                reasonField
                dispatchField
            }
        }
    }

    private var reasonField: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Meldebild", optional: true)
            inputField("z. B. 3 Pkw, eine Person eingeklemmt", text: $form.reason)
        }
    }

    private var dispatchField: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("ILS-Einsatznummer", optional: true)
            inputField("Freitext", text: $form.dispatchNumber)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
    }

    private var startBar: some View {
        VStack(spacing: Spacing.s) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Button(action: startMission) {
                Label("Einsatz starten", systemImage: "play.fill")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.large + 8)
                    .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.l)
        .background(.bar)
    }

    // MARK: Bausteine

    private func sectionLabel(_ title: String, optional: Bool = false) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(title).fontWeight(.semibold)
            if optional { Text("(optional)") }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }

    private func inputField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(.title3)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: TouchTarget.comfortable + 8)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card + 2, style: .continuous))
    }

    private func startMission() {
        errorMessage = nil
        do {
            try start(form)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Neuer Einsatz") {
    NewMissionView(commanderName: "Erika Beispiel") { _ in }
}
