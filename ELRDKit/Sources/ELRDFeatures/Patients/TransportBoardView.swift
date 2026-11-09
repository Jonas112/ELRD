import SwiftUI
import UniformTypeIdentifiers
import ELRDDomain
import ELRDStore

/// Transport-Board der Patientenablage (Schritt 70): wartet → eingeteilt → abgefahren.
///
/// Reihenfolge in „Wartet“ = Transportreihenfolge (schwerste zuerst, dann wer am
/// längsten wartet). Karten lassen sich zwischen den Spalten ziehen:
/// - nach „Eingeteilt“: Transportmittel wählen
/// - nach „Abgefahren“: Transport beginnt
/// - zurück nach „Eingeteilt“: Transport zurücknehmen
/// - zurück nach „Wartet“: Transportmittel lösen
struct TransportBoardView: View {
    let store: MissionStore
    let now: Date
    let onOpen: (PatientID) -> Void

    @State private var pickingUnitFor: PatientID?
    @State private var errorMessage: String?

    var body: some View {
        let columns = TransportBoard.columns(store.state)
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.l) {
                    ForEach(TransportStage.allCases) { stage in
                        column(stage, patients: columns[stage] ?? [])
                            .frame(minWidth: 260, maxWidth: .infinity)
                    }
                }
                // iPhone: Spalten untereinander; Ziehen bleibt möglich, Knöpfe an der Karte genügen.
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ForEach(TransportStage.allCases) { stage in
                        column(stage, patients: columns[stage] ?? [])
                    }
                }
            }
        }
        .sheet(item: Binding(get: { pickingUnitFor.map(PickTarget.init) }, set: { pickingUnitFor = $0?.id })) { target in
            UnitPickerSheet(store: store, patientID: target.id)
        }
    }

    private struct PickTarget: Identifiable {
        let id: PatientID
    }

    private func column(_ stage: TransportStage, patients: [Patient]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(stage.title).font(.title3.weight(.bold))
                Spacer()
                Text("\(patients.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.s)
            if patients.isEmpty {
                Text(emptyText(stage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            }
            ForEach(Array(patients.enumerated()), id: \.element.id) { index, patient in
                card(patient, stage: stage, position: stage == .waiting ? index + 1 : nil)
                    .draggable(patient.id.rawValue.uuidString)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = PatientID(uuidString: raw) else { return false }
            move(id, to: stage)
            return true
        }
    }

    private func emptyText(_ stage: TransportStage) -> String {
        switch stage {
        case .waiting: "Niemand wartet."
        case .assigned: "Hierher ziehen, um ein Transportmittel einzuteilen."
        case .departed: "Noch niemand abgefahren."
        }
    }

    private func card(_ patient: Patient, stage: TransportStage, position: Int?) -> some View {
        let units = unitNames(patient)
        return HStack(alignment: .top, spacing: Spacing.m) {
            if let position {
                Text("\(position).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            Text(patient.triage.shortName)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.onTriage(patient.triage))
                .frame(minWidth: 52, minHeight: 36)
                .background(Color.triage(patient.triage), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(patient.fullName.isEmpty ? patient.number.description : "\(patient.number) – \(patient.fullName)")
                    .font(.headline)
                    .lineLimit(1)
                Text(detail(patient, stage: stage, units: units))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.xs)
            action(patient, stage: stage)
        }
        .padding(Spacing.s)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onOpen(patient.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Öffnen") { onOpen(patient.id) }
    }

    @ViewBuilder
    private func action(_ patient: Patient, stage: TransportStage) -> some View {
        switch stage {
        case .waiting:
            Button { pickingUnitFor = patient.id } label: {
                Image(systemName: "box.truck.badge.clock")
                    .font(.title3)
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
            }
            .accessibilityLabel("Transportmittel einteilen")
        case .assigned:
            Button { move(patient.id, to: .departed) } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
            }
            .accessibilityLabel("Abgefahren")
        case .departed:
            // Schritt 96: am Transportziel → Status 8.
            let transport = store.state.units.filter { patient.unitIDs.contains($0.id) && $0.type.transportsPatients }
            if transport.contains(where: { $0.status != .atDestination }) {
                Button {
                    do {
                        for unit in transport where unit.status != .atDestination {
                            try store.perform(SetUnitStatus(unitID: unit.id, status: .atDestination))
                        }
                        errorMessage = nil
                    } catch {
                        errorMessage = ErrorText.message(for: error)
                    }
                } label: {
                    Text("S 8")
                        .font(.headline.weight(.heavy))
                        .frame(width: TouchTarget.minimum + 8, height: TouchTarget.minimum)
                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("Am Transportziel (Status 8)")
            }
        }
    }

    private func detail(_ patient: Patient, stage: TransportStage, units: String) -> String {
        switch stage {
        case .waiting:
            let minutes = max(0, Int(now.timeIntervalSince(patient.metadata.createdAt) / 60))
            return units.isEmpty ? "wartet seit \(minutes) min" : "wartet seit \(minutes) min · \(units)"
        case .assigned:
            return [units, patient.destination?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " → ")
        case .departed:
            let time = patient.outcome?.date.formatted(date: .omitted, time: .shortened) ?? ""
            return [time, patient.destination?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private func unitNames(_ patient: Patient) -> String {
        store.state.units.filter { patient.unitIDs.contains($0.id) }.map(\.displayName).joined(separator: ", ")
    }

    private func move(_ id: PatientID, to target: TransportStage) {
        guard let patient = store.state.patients.active.first(where: { $0.id == id }),
              let current = TransportBoard.stage(of: patient, units: store.state.units),
              current != target else { return }
        do {
            switch (current, target) {
            case (.waiting, .assigned):
                pickingUnitFor = id
            case (.assigned, .departed):
                try store.perform(StartTransport(patientID: id))
            case (.waiting, .departed):
                errorMessage = "Erst ein Transportmittel einteilen."
                pickingUnitFor = id
                return
            case (.departed, .assigned), (.departed, .waiting):
                try store.perform(ResetOutcome(patientID: id))
                if target == .waiting { try releaseTransportUnits(id) }
            case (.assigned, .waiting):
                try releaseTransportUnits(id)
            default:
                break
            }
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func releaseTransportUnits(_ id: PatientID) throws {
        guard let patient = store.state.patients.active.first(where: { $0.id == id }) else { return }
        let transport = store.state.units.filter { patient.unitIDs.contains($0.id) && $0.type.transportsPatients }
        for unit in transport {
            try store.perform(UnassignUnit(patientID: id, unitID: unit.id))
        }
    }
}
