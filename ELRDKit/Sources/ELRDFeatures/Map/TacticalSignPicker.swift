import SwiftUI
import ELRDDomain

/// Auswahl eines taktischen Zeichens (Schritt 114): große Kacheln je Gruppe,
/// ein Tipp setzt das Zeichen in die Kartenmitte.
struct TacticalSignPicker: View {
    let onPick: (TacticalSignPreset) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ForEach(TacticalSignPreset.Group.allCases, id: \.self) { group in
                        let presets = TacticalSignPreset.all.filter { $0.group == group }
                        if !presets.isEmpty {
                            Text(group.rawValue).font(.title3.weight(.bold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.m)], spacing: Spacing.m) {
                                ForEach(presets) { preset in tile(preset) }
                            }
                        }
                    }
                    Text("Zeichen nach DV 102 „Taktische Zeichen im Bevölkerungsschutz“. Kurztext und Farbe lassen sich danach ändern.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.l)
            }
            .background(Surface.canvas)
            .navigationTitle("Taktisches Zeichen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
        }
    }

    private func tile(_ preset: TacticalSignPreset) -> some View {
        Button {
            onPick(preset)
            dismiss()
        } label: {
            VStack(spacing: Spacing.s) {
                Image(uiImage: TacticalSignRenderer.image(for: preset.sign, height: 52))
                    .frame(height: 64)
                Text(preset.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.large * 1.6)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Surface.separator))
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
    }
}
