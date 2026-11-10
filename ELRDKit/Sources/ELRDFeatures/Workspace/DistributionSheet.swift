import SwiftUI
import ELRDDomain
import ELRDStore

/// Verteilungsvorschlag Kliniken (Schritt 108): Die App schlägt je Patient eine
/// Zielklinik vor (SK, freie Kontingente, Entfernung); die Einsatzleitung hakt ab,
/// ändert einzelne Zeilen und übernimmt. Nichts wird ohne Bestätigung gesetzt (E113).
struct DistributionSheet: View {
    let store: MissionStore
    let hospitals: [MasterHospital]

    @Environment(\.dismiss) private var dismiss
    /// Abgewählte Vorschläge.
    @State private var excluded: Set<PatientID> = []
    /// Von Hand geänderte Kliniken.
    @State private var overrides: [PatientID: HospitalSnapshot] = [:]
    @State private var errorMessage: String?

    var body: some View {
        let plan = HospitalDistribution.propose(store.state, hospitals: hospitals)
        let loads = HospitalDistribution.loads(store.state).filter { $0.quota != nil }
        let selected = plan.proposals.filter { !excluded.contains($0.patientID) }
        NavigationStack {
            List {
                if !plan.hasQuotas {
                    Section {
                        Label("Erst Kontingente eintragen", systemImage: "building.2")
                            .font(.headline)
                        Text("Der Vorschlag verteilt nur auf freie Plätze, die für eine Klinik je SK eingetragen sind.")
                            .foregroundStyle(.secondary)
                    }
                } else if plan.isEmpty {
                    Section {
                        Text("Alle gesichteten Patienten (SK1–SK3) haben bereits eine Zielklinik.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !plan.proposals.isEmpty {
                    Section {
                        ForEach(plan.proposals) { proposal in
                            proposalRow(proposal, loads: loads)
                        }
                    } header: {
                        Text("Vorschläge")
                    } footer: {
                        Text(store.state.mission.coordinate == nil
                             ? "Ohne Einsatzort auf der Karte ist keine Entfernung bekannt. Die Entscheidung trifft die Einsatzleitung."
                             : "Entfernung als Luftlinie vom Einsatzort. Die Entscheidung trifft die Einsatzleitung.")
                    }
                }
                if !plan.undistributed.isEmpty {
                    Section("Ohne Vorschlag") {
                        ForEach(plan.undistributed) { patient in
                            HStack(spacing: Spacing.m) {
                                badge(patient.triage)
                                Text(patient.number).font(.headline.monospacedDigit())
                                Spacer()
                                Text(patient.reason).foregroundStyle(.orange)
                            }
                            .frame(minHeight: TouchTarget.minimum)
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Verteilung vorschlagen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Übernehmen" : "Übernehmen (\(selected.count))") { apply(selected) }
                        .fontWeight(.bold)
                        .disabled(selected.isEmpty || store.state.mission.isClosed)
                }
            }
        }
    }

    private func proposalRow(_ proposal: DistributionProposal, loads: [HospitalLoad]) -> some View {
        let isSelected = !excluded.contains(proposal.patientID)
        let hospital = overrides[proposal.patientID] ?? proposal.hospital
        let isChanged = overrides[proposal.patientID] != nil
        return HStack(spacing: Spacing.m) {
            Button {
                if isSelected { excluded.insert(proposal.patientID) } else { excluded.remove(proposal.patientID) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isSelected ? "Patient \(proposal.number) abwählen" : "Patient \(proposal.number) auswählen")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.s) {
                    badge(proposal.triage)
                    Text(proposal.number).font(.headline.monospacedDigit())
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                }
                Text(hospital.name).font(.headline)
                Text(isChanged ? "Von Hand geändert" : proposal.reason)
                    .font(.subheadline)
                    .foregroundStyle(proposal.traumaRoom != .none && !isChanged ? Color.orange : Color.secondary)
            }
            .opacity(isSelected ? 1 : 0.5)
            Spacer(minLength: Spacing.s)
            Menu {
                ForEach(loads) { load in
                    let option = HospitalDistribution.resolvedHospital(load, hospitals: hospitals)
                    Button {
                        if option == proposal.hospital {
                            overrides[proposal.patientID] = nil
                        } else {
                            overrides[proposal.patientID] = option
                        }
                        excluded.remove(proposal.patientID)
                    } label: {
                        Text(optionTitle(load, triage: proposal.triage))
                    }
                }
            } label: {
                Text("Ändern")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
            }
            .accessibilityLabel("Klinik für Patient \(proposal.number) ändern")
        }
        .frame(minHeight: TouchTarget.comfortable)
    }

    private func optionTitle(_ load: HospitalLoad, triage: Sichtungskategorie) -> String {
        guard let remaining = load.remaining(triage) else { return "\(load.name) – kein Kontingent für \(triage.shortName)" }
        return "\(load.name) – \(max(0, remaining)) frei für \(triage.shortName)"
    }

    private func badge(_ triage: Sichtungskategorie) -> some View {
        Text(triage.shortName)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(Color.onTriage(triage))
            .frame(width: 52, height: 30)
            .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func apply(_ selected: [DistributionProposal]) {
        let assignments = selected.map { proposal in
            ApplyDistribution.Assignment(patientID: proposal.patientID, hospital: overrides[proposal.patientID] ?? proposal.hospital)
        }
        do {
            try store.perform(ApplyDistribution(assignments))
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
