import SwiftUI
import ELRDDomain
import ELRDStammdaten

/// Mitgelieferte Region laden (Fahrzeuge, Kliniken) – solange es die Einstellungen
/// (Schritt 48) noch nicht gibt, direkt von dort, wo die Daten fehlen.
struct RegionImportSheet: View {
    let masterData: MasterDataEditor

    @Environment(\.dismiss) private var dismiss
    @State private var result: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Fahrzeuge und Kliniken einer Region übernehmen. Vorhandene Einträge bleiben, doppelte werden übersprungen.")
                        .foregroundStyle(.secondary)
                    if let result {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    ForEach(BundledMasterData.regions) { region in
                        row(region)
                    }
                }
                .padding(Spacing.xl)
            }
            .background(Surface.canvas)
            .navigationTitle("Region laden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
        }
    }

    private func row(_ region: RegionDefinition) -> some View {
        let isLoaded = masterData.loadedRegionIDs.contains(region.id)
        let contents = [region.hasUnits ? "Fahrzeuge" : nil, region.hasHospitals ? "Kliniken" : nil].compactMap { $0 }
        return Button { load(region) } label: {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(region.name).font(.headline).foregroundStyle(.primary)
                    Text(contents.joined(separator: " und ")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Label(isLoaded ? "geladen" : "Laden", systemImage: isLoaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.headline)
                    .foregroundStyle(isLoaded ? Color.green : ActionFill.primary)
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 64)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(region.name): \(contents.joined(separator: " und ")) \(isLoaded ? "schon geladen" : "laden")")
    }

    private func load(_ region: RegionDefinition) {
        do {
            let report = try masterData.importRegion(region)
            errorMessage = nil
            var parts: [String] = []
            if region.hasUnits { parts.append("\(report.unitsAdded) Fahrzeuge") }
            if region.hasHospitals { parts.append("\(report.hospitalsAdded) Kliniken") }
            result = "\(region.name): \(parts.joined(separator: ", ")) übernommen"
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Hinweis mit Knopf, wenn noch keine Fahrzeuge in den Stammdaten stehen.
struct LoadRegionHint: View {
    let masterData: MasterDataEditor
    @State private var showsImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Noch keine Fahrzeuge in den Stammdaten. Funkrufnamen lassen sich eintippen – oder eine mitgelieferte Region laden.")
                .foregroundStyle(.secondary)
            Button { showsImport = true } label: {
                Label("Region laden (Fahrzeuge, Kliniken)", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: TouchTarget.comfortable)
                    .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showsImport) {
            RegionImportSheet(masterData: masterData)
        }
    }
}
