import SwiftUI
import ELRDDomain
import ELRDStore

/// Suche über Einheiten im Einsatz und Stammdaten (ohne Oberfläche testbar).
struct UnitPickerSearch: Equatable {
    var text = ""

    private var words: [Substring] { text.split(whereSeparator: \.isWhitespace) }

    func matches(_ haystack: String) -> Bool {
        words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func filter(_ choices: [UnitChoice]) -> [UnitChoice] {
        choices.filter { matches("\($0.unit.typeDisplayName) \($0.unit.displayName)") }
    }

    /// Stammdaten-Fahrzeuge, die noch nicht im Einsatz sind – nur bei Suchtext,
    /// damit die Liste schlank bleibt (eine Region hat Dutzende Fahrzeuge).
    func masterUnits(_ master: [MasterUnit], excluding units: [MissionUnit]) -> [MasterUnit] {
        guard !words.isEmpty else { return [] }
        let inMission = Set(units.active.compactMap { $0.callsign?.lowercased() })
        let matching = master
            .filter { !inMission.contains($0.callsign.lowercased()) }
            .filter { matches("\($0.typeDisplayName) \($0.callsign)") }
        return matching.sorted {
            (UnitChoice.typeRank($0.type), $0.callsign) < (UnitChoice.typeRank($1.type), $1.callsign)
        }
    }

    /// Text für „als neue Einheit anlegen“, wenn er zu keiner Einheit passt.
    func newCallsign(units: [MissionUnit], master: [MasterUnit]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let known = units.active.compactMap(\.callsign) + master.map(\.callsign)
        return known.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ? nil : trimmed
    }
}

/// Eigene Liste für Transportmittel und weitere Einheiten am Patienten – wie die
/// Klinikauswahl: Suche oben, Zugeordnete, freie, belegte Einheiten; dazu
/// Fahrzeuge aus den Stammdaten und neue Einheiten direkt anlegen und zuordnen.
struct UnitPickerSheet: View {
    let store: MissionStore
    let patientID: PatientID
    var masterUnits: [MasterUnit] = []

    @Environment(\.dismiss) private var dismiss
    @State private var search = UnitPickerSearch()
    @State private var newType: UnitType = .rtw
    @State private var errorMessage: String?

    private static let newTypes: [UnitType] = [.rtw, .ktw, .ktwKatS, .rth, .nef]

    var body: some View {
        let choices = UnitChoice.ordered(units: store.state.units, patients: store.state.patients, for: patientID)
        let filtered = search.filter(choices)
        let master = search.masterUnits(masterUnits, excluding: store.state.units)
        let newCallsign = search.newCallsign(units: store.state.units, master: masterUnits)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Funkrufname oder Typ suchen – oder neu eintippen", text: $search.text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                    .inputBox()

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    if let newCallsign { newUnitPanel(newCallsign) }

                    if !filtered.isEmpty || search.text.isEmpty {
                        UnitAssignmentSection(
                            choices: filtered,
                            onAssign: assign,
                            onUnassign: { perform(UnassignUnit(patientID: patientID, unitID: $0)) }
                        )
                    }

                    if !master.isEmpty {
                        masterSection(master)
                    } else if search.text.isEmpty, !masterUnits.isEmpty {
                        Label("Weitere \(masterUnits.count) Fahrzeuge aus den Stammdaten: oben Funkrufname eintippen.", systemImage: "magnifyingglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.canvas)
            .navigationTitle("Transportmittel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }

    // MARK: Hinzufügen

    /// Unbekannter Funkrufname: Typ wählen, anlegen und gleich zuordnen.
    private func newUnitPanel(_ callsign: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("„\(callsign)“ neu zum Einsatz hinzufügen").font(.headline)
            FlowLayout(spacing: Spacing.s) {
                ForEach(Self.newTypes, id: \.self) { type in
                    ChoiceChip(type.shortName, isSelected: newType == type, minHeight: TouchTarget.minimum + 4) { newType = type }
                }
            }
            Button {
                addTemporary(callsign)
            } label: {
                Label("Anlegen und zuordnen", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: TouchTarget.comfortable)
                    .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    private func masterSection(_ units: [MasterUnit]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Aus den Stammdaten – antippen fügt hinzu und ordnet zu")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Spacing.s)], spacing: Spacing.s) {
                ForEach(units.prefix(24)) { unit in
                    Button { addMaster(unit) } label: {
                        HStack(spacing: Spacing.m) {
                            Text(unit.typeDisplayName)
                                .font(.subheadline.weight(.heavy))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: 52, height: 36)
                                .background(Surface.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(unit.callsign).font(.headline).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                                Text("hinzufügen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle").font(.title2).foregroundStyle(ActionFill.primary)
                        }
                        .padding(.horizontal, Spacing.m)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(unit.typeDisplayName) \(unit.callsign) zum Einsatz hinzufügen und zuordnen")
                }
            }
        }
    }

    // MARK: Aktionen

    /// Ein Transportmittel zuordnen schließt die Liste (wie bei der Klinik);
    /// begleitende Einheiten (NEF …) lassen sie offen.
    private func assign(_ unitID: UnitID) {
        guard perform(AssignUnit(patientID: patientID, unitID: unitID)) else { return }
        if store.state.units.first(where: { $0.id == unitID })?.type.transportsPatients == true { dismiss() }
    }

    private func addTemporary(_ callsign: String) {
        do {
            let unit = try store.perform(AddTemporaryUnit(callsign: callsign, type: newType))
            search.text = ""
            assign(unit.id)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func addMaster(_ master: MasterUnit) {
        do {
            let added = try store.perform(AddMasterUnits([master]))
            search.text = ""
            if let unit = added.first { assign(unit.id) }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    @discardableResult
    private func perform<Command: MissionCommand>(_ command: Command) -> Bool {
        do {
            _ = try store.perform(command)
            errorMessage = nil
            return true
        } catch {
            errorMessage = ErrorText.message(for: error)
            return false
        }
    }
}
