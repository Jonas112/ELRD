import SwiftUI
import ELRDDomain
import ELRDStore

/// Alle Kliniken: Suche, Liste (gewählte und nächste zuerst), Freitext.
struct HospitalPickerView: View {
    let choices: [HospitalChoice]
    let current: HospitalSnapshot?
    /// Freie Plätze laut Kontingent (Schritt 71).
    var capacity: (HospitalSnapshot) -> HospitalCapacity? = { _ in nil }
    let onSelect: (HospitalSnapshot?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let filtered = HospitalChoice.filter(choices, search: search)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Klinik oder Ort suchen", text: $search)
                            .autocorrectionDisabled()
                    }
                    .inputBox()

                    let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty && !filtered.contains(where: { $0.hospital.name.caseInsensitiveCompare(text) == .orderedSame }) {
                        Button {
                            choose(HospitalSnapshot(name: text, address: "", city: "", phone: "", email: ""))
                        } label: {
                            Label("„\(text)“ als Klinik eintragen", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable, alignment: .leading)
                        }
                    }

                    if choices.isEmpty {
                        Text("Noch keine Kliniken in den Stammdaten. In der Einsatzliste unter Einstellungen → Stammdaten → „Region laden“ übernehmen; bis dahin die Klinik oben als Text eintragen.")
                            .foregroundStyle(.secondary)
                    }

                    LazyVStack(spacing: Spacing.s) {
                        ForEach(filtered) { choice in
                            Button { choose(choice.hospital.snapshot) } label: {
                                HospitalRow(choice: choice, isSelected: current?.masterHospitalID == choice.hospital.id, capacity: capacity(choice.hospital.snapshot))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.canvas)
            .navigationTitle("Zielklinik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                if current != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Entfernen", role: .destructive) { choose(nil) }
                    }
                }
            }
        }
    }

    private func choose(_ hospital: HospitalSnapshot?) {
        onSelect(hospital)
        dismiss()
    }
}

/// Zeile einer Klinik mit Ort, Entfernung und „im Einsatz gewählt“.
struct HospitalRow: View {
    let choice: HospitalChoice
    let isSelected: Bool
    var capacity: HospitalCapacity?

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.hospital.name).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            if let capacity {
                Text(capacity.text)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(capacity.isFull ? Color.white : Color.primary)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xxs)
                    .background(capacity.isFull ? Color.orange : Surface.elevated, in: Capsule())
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 64)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = [choice.hospital.city]
        if let distance = choice.distanceText { parts.append(distance) }
        if choice.usedInMission > 0 { parts.append("im Einsatz \(choice.usedInMission)×") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Freie Plätze einer Klinik für die SK des Patienten (Schritt 71).
struct HospitalCapacity: Equatable {
    let remaining: Int
    let triage: Sichtungskategorie

    init?(hospital: HospitalSnapshot, triage: Sichtungskategorie, state: MissionState) {
        guard let load = HospitalDistribution.load(of: hospital, in: state),
              let remaining = load.remaining(triage) else { return nil }
        self.remaining = remaining
        self.triage = triage
    }

    var isFull: Bool { remaining <= 0 }

    var text: String {
        remaining > 0 ? "\(triage.shortName): \(remaining) frei" : "\(triage.shortName): voll"
    }
}

