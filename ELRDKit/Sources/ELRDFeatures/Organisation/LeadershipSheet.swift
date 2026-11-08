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
                                reach: [position.callsign, position.radioChannel].filter { !$0.isEmpty },
                                footer: nil
                            ) { editing = .role(role) }
                        }
                    }
                    Text("Abschnitte").font(.title2.weight(.bold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.m)], spacing: Spacing.m) {
                        ForEach(forces.sections) { force in
                            let section = force.section
                            box(
                                title: section.name,
                                subtitle: section.isInitial ? "Initialabschnitt" : "Abschnitt",
                                name: section.leaderName ?? "",
                                reach: [section.leaderCallsign, section.radioChannel].compactMap { $0 },
                                footer: sectionFooter(force)
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
            PositionEditor(title: role.displayName, role: role, name: position.name, callsign: position.callsign, channel: position.radioChannel) { name, callsign, channel in
                try store.perform(SetLeadershipPosition(LeadershipPosition(role: role, name: name, callsign: callsign, radioChannel: channel)))
            }
        case .section(let id):
            if let section = store.state.activeSections.first(where: { $0.id == id }) {
                PositionEditor(title: "Leitung \(section.name)", role: nil, name: section.leaderName ?? "", callsign: section.leaderCallsign ?? "", channel: section.radioChannel ?? "") { name, callsign, channel in
                    try store.perform(SetSectionLeader(sectionID: id, name: name, callsign: callsign, radioChannel: channel))
                }
            }
        }
    }
}

/// Name, Funkrufname und Kanal einer Funktion.
private struct PositionEditor: View {
    let title: String
    /// Funktion (`nil` = Abschnittsleitung) – bestimmt, wer aus der Liste passt.
    let role: LeadershipRole?
    @State var name: String
    @State var callsign: String
    @State var channel: String
    let onSave: (String, String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @State private var errorMessage: String?

    init(title: String, role: LeadershipRole?, name: String, callsign: String, channel: String, onSave: @escaping (String, String, String) throws -> Void) {
        self.title = title
        self.role = role
        _name = State(initialValue: name)
        _callsign = State(initialValue: callsign)
        _channel = State(initialValue: channel)
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
                                name = person.name
                                callsign = person.callsign
                                channel = person.radioChannel
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.name).font(.headline).foregroundStyle(.primary)
                                        let reach = [person.callsign, person.radioChannel].filter { !$0.isEmpty }.joined(separator: " · ")
                                        if !reach.isEmpty { Text(reach).font(.subheadline).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if person.name == name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                                .frame(minHeight: TouchTarget.minimum)
                            }
                        }
                    }
                }
                Section {
                    TextField("Name", text: $name).frame(minHeight: TouchTarget.minimum)
                    TextField("Funkrufname", text: $callsign).frame(minHeight: TouchTarget.minimum)
                    TextField("Funkkanal (z. B. TMO 312)", text: $channel).frame(minHeight: TouchTarget.minimum)
                } footer: {
                    Text("Alle Felder leeren, um die Funktion zu entfernen.")
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
                            try onSave(name, callsign, channel)
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
