import SwiftUI
import ELRDDomain
import ELRDStore

/// Vorschau eines neuen FE2-Stands vor dem Übernehmen (Schritt 143, E129).
///
/// Oben steht, was aus Alamos FE2 empfangen wurde (vollständiger Stand), darunter das
/// Neue seit der letzten Übernahme – jeder Punkt einzeln wählbar. Nicht Ausgewähltes
/// bleibt im Einsatz als Hinweis offen.
struct AlamosUpdateSheet: View {
    let update: AlarmUpdate
    /// Übernimmt die Auswahl; Fehlertext oder `nil` bei Erfolg.
    let onApply: (AlarmUpdateSelection) -> String?

    @State private var selection: AlarmUpdateSelection
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(update: AlarmUpdate, onApply: @escaping (AlarmUpdateSelection) -> String?) {
        self.update = update
        self.onApply = onApply
        _selection = State(initialValue: update.fullSelection)
    }

    var body: some View {
        let data = update.alarm.data
        let changes = update.changes
        NavigationStack {
            List {
                received(data)

                if changes.keyword != nil || changes.address != nil || !changes.messageLines.isEmpty {
                    Section {
                        if let keyword = changes.keyword {
                            choice(isOn: binding(\.keyword), title: "Stichwort geändert", detail: keyword, systemImage: "exclamationmark.bubble")
                        }
                        if let address = changes.address {
                            choice(isOn: binding(\.address), title: "Einsatzort geändert", detail: address, systemImage: "mappin.and.ellipse")
                        }
                        if !changes.messageLines.isEmpty {
                            choice(isOn: binding(\.message), title: "Alarmtext ergänzt", detail: changes.messageLines.joined(separator: "\n"), systemImage: "text.bubble")
                        }
                    } header: {
                        Text("Ins Einsatztagebuch")
                    } footer: {
                        Text("Stichwort und Einsatzort des Einsatzes bleiben unverändert; die Änderung wird im Tagebuch vermerkt.")
                    }
                }

                if !update.vehicles.isEmpty {
                    Section {
                        ForEach(update.vehicles, id: \.callsign) { match in
                            let key = MasterDataMatching.key(match.callsign)
                            choice(
                                isOn: member(key, in: \.vehicleKeys),
                                title: match.callsign,
                                detail: "\(match.type.shortName) · \(match.master != nil ? "aus den Stammdaten" : "temporär (Typ geschätzt)")",
                                systemImage: "car.2"
                            )
                        }
                    } header: {
                        Text("Nachalarmierte Fahrzeuge (\(update.vehicles.count))")
                    } footer: {
                        Text("Werden im Initialabschnitt angelegt.")
                    }
                }

                if !changes.patients.isEmpty {
                    Section {
                        ForEach(Array(changes.patientKeys.enumerated()), id: \.element) { index, key in
                            let patient = changes.patients[index]
                            choice(
                                isOn: member(key, in: \.patientKeys),
                                title: patientTitle(patient),
                                detail: [patient.remark, patient.destination.map { "Ziel: \($0)" }].compactMap { $0 }.joined(separator: "\n"),
                                systemImage: "person.badge.plus"
                            )
                        }
                    } header: {
                        Text("Gemeldete Patienten (\(changes.patients.count))")
                    } footer: {
                        Text("Werden ungesichtet angelegt; Bemerkung und Ziel der Leitstelle stehen in der Notiz.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Neuer Stand aus Alamos FE2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Alles auswählen") { selection = update.fullSelection }
                        Button("Nichts auswählen") { selection = AlarmUpdateSelection() }
                    } label: {
                        Label("Auswahl", systemImage: "checklist")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .alert("Übernehmen nicht möglich", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Was empfangen wurde: der vollständige aktuelle Stand.
    private func received(_ data: AlamosAlarmData) -> some View {
        Section {
            LabeledContent("Einsatznummer", value: update.alarm.externalId)
            LabeledContent("Stand", value: "\(update.alarm.revision) · \(update.alarm.updatedAt.formatted(date: .omitted, time: .shortened))")
            if let sender = update.alarm.sender { LabeledContent("Absender", value: sender) }
            LabeledContent("Stichwort", value: [data.keyword, data.keywordDescription].compactMap { $0 }.joined(separator: " – ").nonEmptyOr("–"))
            if let address = data.location?.addressLine, !address.isEmpty {
                LabeledContent("Einsatzort", value: address)
            }
            if !data.messageLines.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Alarmtext").font(.subheadline).foregroundStyle(.secondary)
                    Text(data.messageLines.joined(separator: "\n")).textSelection(.enabled)
                }
            }
            LabeledContent("Fahrzeuge", value: data.callsigns.isEmpty ? "keine" : data.callsigns.joined(separator: ", "))
            LabeledContent("Gemeldete Patienten", value: "\(data.patients.count)")
        } header: {
            Text("Empfangen")
        } footer: {
            Text("So hat das ELRD-Backend den Einsatz zuletzt geliefert. Unten steht, was davon neu ist und übernommen werden kann.")
        }
    }

    private func choice(isOn: Binding<Bool>, title: String, detail: String, systemImage: String) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(.body.weight(.semibold))
                    if !detail.isEmpty {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .frame(minHeight: TouchTarget.minimum)
    }

    private func patientTitle(_ patient: AlamosPatient) -> String {
        let number = patient.patientNumber.map { "Patient \($0)" } ?? "Patient ohne Nummer"
        guard let name = patient.name else { return number }
        return "\(number) – \(name)"
    }

    private func binding(_ path: WritableKeyPath<AlarmUpdateSelection, Bool>) -> Binding<Bool> {
        Binding(get: { selection[keyPath: path] }, set: { selection[keyPath: path] = $0 })
    }

    private func member(_ key: String, in path: WritableKeyPath<AlarmUpdateSelection, Set<String>>) -> Binding<Bool> {
        Binding(
            get: { selection[keyPath: path].contains(key) },
            set: { isOn in
                if isOn { selection[keyPath: path].insert(key) } else { selection[keyPath: path].remove(key) }
            }
        )
    }

    private var actionBar: some View {
        VStack(spacing: Spacing.xs) {
            Button {
                if let error = onApply(selection) {
                    errorMessage = error
                } else {
                    dismiss()
                }
            } label: {
                Label(selection.count == 1 ? "1 Punkt übernehmen" : "\(selection.count) Punkte übernehmen", systemImage: "square.and.arrow.down.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(selection.isEmpty)
            if selection != update.fullSelection {
                Text("Nicht Ausgewähltes bleibt im Einsatz als Hinweis offen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
        .background(.bar)
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}
