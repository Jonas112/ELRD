import SwiftUI
import ELRDDomain
import ELRDStore

/// Einsatzdaten bearbeiten, Einsatz beenden oder wieder öffnen.
///
/// Erreichbar über einen Tipp auf den Einsatztitel in der Lageleiste.
struct MissionDetailsView: View {
    let store: MissionStore
    let people: [PersonChoice]

    @Environment(\.dismiss) private var dismiss
    @State private var form: MissionEditForm
    @State private var errorMessage: String?
    @State private var confirmsClose = false

    init(store: MissionStore, people: [PersonChoice]) {
        self.store = store
        self.people = people
        _form = State(initialValue: MissionEditForm(mission: store.state.mission))
    }

    var body: some View {
        let mission = store.state.mission
        let problems = form.problems(applyingTo: mission)
        NavigationStack {
            Form {
                if mission.isClosed { closedSection(mission) }

                Group {
                    missionSection(mission)
                    timeSection(mission)
                    commanderSection
                }
                .disabled(mission.isClosed)

                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.message) { problem in
                            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if !mission.isClosed { closeSection }
                if !store.state.trash.isEmpty { trashSection(store.state.trash, canRestore: !mission.isClosed) }
            }
            .environment(\.defaultMinListRowHeight, TouchTarget.comfortable)
            .navigationTitle("Einsatzdaten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { if save() { dismiss() } }
                        .fontWeight(.bold)
                        .disabled(!problems.isEmpty)
                }
            }
            .confirmationDialog("Einsatz beenden?", isPresented: $confirmsClose, titleVisibility: .visible) {
                Button("Einsatz beenden", role: .destructive, action: closeMission)
            } message: {
                Text(closeMessage)
            }
        }
        .interactiveDismissDisabled(form.hasChanges)
    }

    // MARK: Abschnitte

    private func closedSection(_ mission: Mission) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label("Einsatz beendet", systemImage: "flag.checkered")
                    .font(.title3.weight(.bold))
                if let endedAt = mission.endedAt {
                    Text("Ende: \(endedAt.formatted(date: .numeric, time: .shortened)). Zum Ändern zuerst wieder öffnen.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.s)
            Button(action: reopenMission) {
                Label("Einsatz wieder öffnen", systemImage: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
            }
        }
    }

    private func missionSection(_ mission: Mission) -> some View {
        Section("Einsatz") {
            LabeledContent("Einsatznummer", value: mission.displayNumber())
            labeledField("Meldebild", prompt: "z. B. 3 Pkw, eine Person eingeklemmt", text: $form.reason)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Einsatzart").foregroundStyle(.secondary)
                FlowLayout(spacing: Spacing.s) {
                    ForEach(NewMissionForm.typeOrder, id: \.self) { type in
                        ChoiceChip(type.chipLabel, isSelected: form.type == type, minHeight: 48, background: Surface.elevated) {
                            form.type = form.type == type ? nil : type
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.s)
            labeledField("Einsatzort", prompt: "Adresse oder Beschreibung", text: $form.location)
            labeledField("ILS-Einsatznummer", prompt: "Freitext", text: $form.dispatchNumber)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
    }

    private func timeSection(_ mission: Mission) -> some View {
        Section("Zeit") {
            DatePicker("Beginn", selection: $form.startedAt)
            if let ended = Binding($form.endedAt) {
                DatePicker("Ende", selection: ended)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                LabeledContent(mission.isClosed ? "Dauer" : "Läuft seit") {
                    Text(ElapsedTimeFormat.string(from: form.startedAt, to: form.endedAt ?? context.date))
                        .monospacedDigit()
                }
            }
        }
    }

    private var commanderSection: some View {
        Section("Einsatzleiter und Fahrzeug") {
            Picker("Einsatzleiter", selection: $form.commanderID) {
                Text("nicht festgelegt").tag(UserID?.none)
                ForEach(people) { person in
                    Text(person.detail.isEmpty ? person.name : "\(person.name) · \(person.detail)")
                        .tag(Optional(person.id))
                }
            }
            kilometerField("km bei Beginn", text: $form.odometerStart)
            kilometerField("km bei Ende", text: $form.odometerEnd)
            if case let start?? = MissionEditForm.parseKilometers(form.odometerStart),
               case let end?? = MissionEditForm.parseKilometers(form.odometerEnd), end >= start {
                LabeledContent("Gefahren", value: "\(end - start) km")
            }
        }
    }

    private var closeSection: some View {
        Section {
            Button { confirmsClose = true } label: {
                Label("Einsatz beenden", systemImage: "flag.checkered")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
            }
            .listRowBackground(ActionFill.primary)
        } footer: {
            Text("Danach ist der Einsatz schreibgeschützt. Er kann jederzeit wieder geöffnet werden.")
        }
    }

    /// Papierkorb (Schritt 54): gelöschte Patienten, Tagebucheinträge, Kartenobjekte.
    private func trashSection(_ items: [TrashItem], canRestore: Bool) -> some View {
        Section {
            ForEach(items) { item in
                HStack(spacing: Spacing.m) {
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(2)
                        Text("\(item.kind.displayName) · gelöscht \(item.deletedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Spacing.s)
                    if canRestore {
                        Button("Wiederherstellen") { restore(item) }
                            .buttonStyle(.borderless)
                            .font(.headline)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            }
        } header: {
            Text("Papierkorb")
        } footer: {
            Text("Gelöschtes bleibt im Einsatz gespeichert. Wiederherstellen wird im Protokoll vermerkt.")
        }
    }

    private func restore(_ item: TrashItem) {
        do {
            try store.perform(RestoreDeleted(item))
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    // MARK: Bausteine

    private func labeledField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
        }
    }

    private func kilometerField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text("–"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    private var closeMessage: String {
        let open = store.state.patients.active.filter { $0.status == .waiting || $0.status == .assigned }.count
        let hint = "Danach ist der Einsatz schreibgeschützt und kann wieder geöffnet werden."
        switch open {
        case 0: return hint
        case 1: return "1 Patient ist noch nicht abtransportiert oder entlassen. \(hint)"
        default: return "\(open) Patienten sind noch nicht abtransportiert oder entlassen. \(hint)"
        }
    }

    // MARK: Aktionen

    /// Speichert geänderte Felder. `false`, wenn das nicht ging.
    @discardableResult
    private func save() -> Bool {
        guard form.hasChanges, !store.state.mission.isClosed else { return true }
        let form = form
        do {
            try store.perform(EditMission { form.apply(to: &$0) })
            errorMessage = nil
            return true
        } catch {
            errorMessage = ErrorText.message(for: error)
            return false
        }
    }

    private func closeMission() {
        guard save() else { return }
        do {
            try store.perform(CloseMission())
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func reopenMission() {
        do {
            try store.perform(ReopenMission())
            form = MissionEditForm(mission: store.state.mission)
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
