import SwiftUI
import ELRDDomain
import ELRDStore

/// Patient (Zwischenstand bis Schritt 19): Kopf und Sichtung mit einem Tipp ändern.
struct PatientQuickDetailView: View {
    let store: MissionStore
    let patientID: PatientID

    @State private var errorMessage: String?

    var body: some View {
        if let patient = store.state.patients.first(where: { $0.id == patientID }), !patient.metadata.isDeleted {
            content(patient)
        } else {
            ContentUnavailableView("Patient nicht gefunden", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func content(_ patient: Patient) -> some View {
        let canEdit = !store.state.mission.isClosed && store.isEnabled(.missionEditing)
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
                    Text(patient.number.description)
                        .font(.system(size: 44, weight: .heavy))
                        .monospacedDigit()
                    Text(patient.fullName.isEmpty ? "Name unbekannt" : patient.fullName)
                        .font(.title.weight(.bold))
                        .foregroundStyle(patient.fullName.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Sichtungskategorie").font(.headline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.m)], spacing: Spacing.m) {
                        ForEach(Self.order, id: \.self) { category in
                            TriageChoiceButton(category: category, isSelected: patient.triage == category) {
                                setTriage(category)
                            }
                            .disabled(!canEdit)
                        }
                    }
                }

                Label(patient.status.displayName, systemImage: statusSymbol(patient.status))
                    .font(.title3.weight(.semibold))

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text("Personalien, Nummern, Erkennungsmerkmale, Verletzungen, IVENA und Transport folgen in den Schritten 19 bis 22.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Surface.canvas)
        .navigationTitle("Patient \(patient.number)")
        .navigationBarTitleDisplayMode(.inline)
    }

    static let order: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .unverletzt, .ungesichtet, .verstorben]

    private func statusSymbol(_ status: PatientStatus) -> String {
        switch status {
        case .waiting: "hourglass"
        case .assigned: "box.truck"
        case .inTransport: "arrow.right.circle"
        case .released: "checkmark.circle"
        }
    }

    private func setTriage(_ category: Sichtungskategorie) {
        do {
            try store.perform(SetTriage(patientID: patientID, triage: category))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Großer SK-Auswahlknopf: gewählt mit kräftigem Rand, sonst abgeschwächt.
struct TriageChoiceButton: View {
    let category: Sichtungskategorie
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(category == .ungesichtet || category == .unverletzt || category == .verstorben ? category.displayName : category.shortName)
                .font(.title2.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.onTriage(category))
                .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                .background(Color.triage(category), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary, lineWidth: isSelected ? 4 : (TriageBadge.needsOutline(category) ? 1 : 0))
                }
                .opacity(isSelected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
