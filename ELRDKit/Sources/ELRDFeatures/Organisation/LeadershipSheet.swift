import SwiftUI
import ELRDDomain
import ELRDStore

/// Führungsstruktur und Kräfteübersicht (Schritt 73): Einsatzleitung oben,
/// darunter die Abschnitte mit Leitung, Funkkanal, Fahrzeugen und Stärke.
struct LeadershipSheet: View {
    let store: MissionStore

    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var errorMessage: String?

    enum EditTarget: Identifiable {
        case role(LeadershipRole)
        case section(SectionID)

        var id: String {
            switch self {
            case .role(let role): "role-\(role.rawValue)"
            case .section(let id): "section-\(id.rawValue.uuidString)"
            }
        }
    }

    var body: some View {
        let forces = ForceOverview(state: store.state)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    strengthHeader(forces)
                    Text("Einsatzleitung").font(.title2.weight(.bold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.m)], spacing: Spacing.m) {
                        ForEach(LeadershipRole.allCases) { role in
                            let position = store.state.mission.position(role)
                            box(
                                title: role.shortName,
                                subtitle: role.displayName,
                                name: position.name,
                                reach: [position.callsign, position.radioChannel, position.phone ?? ""].filter { !$0.isEmpty },
                                footer: nil
                            ) { editing = .role(role) }
                        }
                    }
                    if let participants = store.state.mission.participants, !participants.isEmpty {
                        ParticipantsSection(store: store, participants: participants) { errorMessage = $0 }
                    }
                    Text("Abschnitte").font(.title2.weight(.bold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.m)], spacing: Spacing.m) {
                        ForEach(forces.sections) { force in
                            let section = force.section
                            box(
                                title: section.name,
                                subtitle: section.isInitial ? "Initialabschnitt" : "Abschnitt",
                                name: section.leaderName ?? "",
                                reach: [section.leaderCallsign, section.radioChannel, section.leaderPhone].compactMap { $0 },
                                footer: [section.task.map { "Auftrag: \($0)" }, sectionFooter(force)].compactMap { $0 }.joined(separator: "\n")
                            ) { editing = .section(section.id) }
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .padding(Spacing.xl)
            }
            .background(Surface.canvas)
            .navigationTitle("Führung und Kräfte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
            .sheet(item: $editing) { target in
                editor(for: target)
            }
        }
    }

    private func strengthHeader(_ forces: ForceOverview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(forces.strengthText ?? "Stärke unbekannt")
                .font(.title.weight(.heavy))
            Text(forces.unitCount == 1 ? "1 Fahrzeug vor Ort" + typeText(forces) : "\(forces.unitCount) Fahrzeuge vor Ort" + typeText(forces))
                .font(.headline)
                .foregroundStyle(.secondary)
            if forces.placeholderCount > 0 {
                Text("Angefordert: \(forces.placeholderSummary)")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func typeText(_ forces: ForceOverview) -> String {
        forces.typeSummary.isEmpty ? "" : " (\(forces.typeSummary))"
    }

    private func sectionFooter(_ force: ForceOverview.SectionForce) -> String {
        let vehicles = force.units.count == 1 ? "1 Fahrzeug" : "\(force.units.count) Fahrzeuge"
        guard force.strength > 0 else { return vehicles }
        return force.unknownCrew > 0 ? "\(vehicles) · Stärke mind. \(force.strength)" : "\(vehicles) · Stärke \(force.strength)"
    }

    private func box(title: String, subtitle: String, name: String, reach: [String], footer: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title3.weight(.heavy))
                    Spacer()
                    Image(systemName: "pencil").foregroundStyle(.tertiary)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Text(name.isEmpty ? "nicht besetzt" : name)
                    .font(.headline)
                    .foregroundStyle(name.isEmpty ? Color.secondary : Color.primary)
                if !reach.isEmpty {
                    Label(reach.joined(separator: " · "), systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let footer {
                    Text(footer).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(store.state.mission.isClosed)
    }

    @ViewBuilder
    private func editor(for target: EditTarget) -> some View {
        switch target {
        case .role(let role):
            let position = store.state.mission.position(role)
            PositionEditor(title: role.displayName, role: role,
                           values: .init(name: position.name, callsign: position.callsign, channel: position.radioChannel, phone: position.phone ?? "")) { values in
                try store.perform(SetLeadershipPosition(LeadershipPosition(role: role, name: values.name, callsign: values.callsign,
                                                                           radioChannel: values.channel, phone: values.phone)))
            }
        case .section(let id):
            if let section = store.state.activeSections.first(where: { $0.id == id }) {
                PositionEditor(title: "Leitung \(section.name)", role: nil,
                               values: .init(name: section.leaderName ?? "", callsign: section.leaderCallsign ?? "", channel: section.radioChannel ?? "",
                                             phone: section.leaderPhone ?? "", task: section.task ?? "")) { values in
                    try store.perform(SetSectionLeader(sectionID: id, name: values.name, callsign: values.callsign, radioChannel: values.channel,
                                                       phone: values.phone, task: values.task))
                }
            }
        }
    }
}

/// Name, Funkrufname, Rufgruppe und Telefon einer Funktion; bei Abschnitten auch
/// der Auftrag (DV 800, Schritt 126).
struct PositionEditor: View {
    struct Values: Equatable {
        var name: String
        var callsign: String
        var channel: String
        var phone: String
        /// `nil` = kein Auftragsfeld (Funktionen der Einsatzleitung).
        var task: String?

        init(name: String, callsign: String, channel: String, phone: String, task: String? = nil) {
            self.name = name
            self.callsign = callsign
            self.channel = channel
            self.phone = phone
            self.task = task
        }
    }

    let title: String
    /// Funktion (`nil` = Abschnittsleitung) – bestimmt, wer aus der Liste passt.
    let role: LeadershipRole?
    @State var values: Values
    let onSave: (Values) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @State private var errorMessage: String?

    init(title: String, role: LeadershipRole?, values: Values, onSave: @escaping (Values) throws -> Void) {
        self.title = title
        self.role = role
        _values = State(initialValue: values)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                let people = (appSettings?.settings.leadershipPeople ?? []).filter { $0.fits(role) }
                if !people.isEmpty {
                    Section("Aus dem Führungspersonal") {
                        ForEach(people) { person in
                            Button {
                                values.name = person.name
                                values.callsign = person.callsign
                                values.channel = person.radioChannel
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.name).font(.headline).foregroundStyle(.primary)
                                        let reach = [person.callsign, person.radioChannel].filter { !$0.isEmpty }.joined(separator: " · ")
                                        if !reach.isEmpty { Text(reach).font(.subheadline).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if person.name == values.name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                                .frame(minHeight: TouchTarget.minimum)
                            }
                        }
                    }
                }
                Section {
                    TextField("Name", text: $values.name).frame(minHeight: TouchTarget.minimum)
                    TextField("Funkrufname", text: $values.callsign).frame(minHeight: TouchTarget.minimum)
                    TextField("Rufgruppe (z. B. TMO 312)", text: $values.channel).frame(minHeight: TouchTarget.minimum)
                    TextField("Telefon / Mobil", text: $values.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .frame(minHeight: TouchTarget.minimum)
                } footer: {
                    Text(values.task == nil ? "Alle Felder leeren, um die Funktion zu entfernen." : "Erscheint im Kommunikationsplan nach DV 800.")
                }
                if values.task != nil {
                    Section("Auftrag") {
                        TextField("z. B. Patientenablage betreiben", text: Binding(get: { values.task ?? "" }, set: { values.task = $0 }), axis: .vertical)
                            .lineLimit(1...4)
                            .frame(minHeight: TouchTarget.minimum)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        do {
                            try onSave(values)
                            dismiss()
                        } catch {
                            errorMessage = ErrorText.message(for: error)
                        }
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Teilnehmer im geteilten Einsatz (Schritt 89): eigener Abschnitt wählbar, die
/// Einsatzleitung vergibt Rechte (E103).
private struct ParticipantsSection: View {
    let store: MissionStore
    let participants: [MissionParticipant]
    let onError: (String?) -> Void

    var body: some View {
        let mission = store.state.mission
        let me = store.sessionUserID
        let isCommander = mission.commanderID == me
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Teilnehmer").font(.title2.weight(.bold))
            ForEach(participants.sorted { $0.joinedAt < $1.joinedAt }) { participant in
                let isMe = participant.id == me?.rawValue
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(participant.displayName.isEmpty ? "Unbekannt" : participant.displayName)
                            .font(.headline)
                        if isMe { Text("ich").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                        if mission.commanderID == participant.userID {
                            Text("Einsatzleitung").font(.caption.weight(.bold)).foregroundStyle(.tint)
                        }
                        Spacer()
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.m) { sectionControl(participant, isMe: isMe); permissionControl(participant, isCommander: isCommander) }
                        VStack(alignment: .leading, spacing: Spacing.s) { sectionControl(participant, isMe: isMe); permissionControl(participant, isCommander: isCommander) }
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text(isCommander
                 ? "Jeder wählt seinen Abschnitt selbst. Rechte: „Eigener Abschnitt“ erlaubt Patienten und Einheiten nur dort, „Nur lesen“ nur Nachrichten."
                 : "Wählen Sie Ihren Abschnitt. Rechte vergibt die Einsatzleitung.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sectionControl(_ participant: MissionParticipant, isMe: Bool) -> some View {
        let sections = store.state.activeSections
        let current = sections.first { $0.id == participant.sectionID }?.name ?? "kein Abschnitt"
        if isMe && !store.state.mission.isClosed {
            Menu {
                Button("Kein Abschnitt") { perform(ChooseOwnSection(nil)) }
                ForEach(sections) { section in
                    Button(section.name) { perform(ChooseOwnSection(section.id)) }
                }
            } label: {
                Label("Mein Abschnitt: \(current)", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: TouchTarget.minimum)
            }
        } else {
            Label(current, systemImage: "square.grid.2x2").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func permissionControl(_ participant: MissionParticipant, isCommander: Bool) -> some View {
        let isLead = store.state.mission.commanderID == participant.userID
        if isCommander && !isLead && !store.state.mission.isClosed {
            Menu {
                ForEach(ParticipantPermission.allCases) { permission in
                    Button {
                        perform(SetParticipantPermission(participantID: participant.id, permission: permission))
                    } label: {
                        if participant.permission == permission {
                            Label(permission.displayName, systemImage: "checkmark")
                        } else {
                            Text(permission.displayName)
                        }
                    }
                }
            } label: {
                Label("Rechte: \(participant.permission.displayName)", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: TouchTarget.minimum)
            }
        } else {
            Label("Rechte: \(isLead ? ParticipantPermission.full.displayName : participant.permission.displayName)", systemImage: "lock.shield")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func perform(_ command: some MissionCommand) {
        do {
            _ = try store.perform(command)
            onError(nil)
        } catch {
            onError(ErrorText.message(for: error))
        }
    }
}
