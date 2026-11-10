import SwiftUI
import ELRDDomain

/// Stammdaten verwalten (Schritt 48): Fahrzeuge, Kliniken, Abschnittsvorlagen;
/// Region laden. Ändern dürfen nur Administratoren, alle anderen sehen nur.
struct MasterDataSettingsView: View {
    enum Kind: Hashable { case units, hospitals, sections }

    let masterData: MasterDataEditor?
    let isAdmin: Bool

    @State private var kind: Kind = .units
    @State private var search = ""
    @State private var editingUnit: MasterUnit?
    @State private var editingHospital: MasterHospital?
    @State private var newSection = ""
    @State private var showsRegions = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let masterData {
                content(masterData)
            } else {
                ContentUnavailableView("Keine Stammdaten", systemImage: "tray", description: Text("Nach der Anmeldung verfügbar."))
            }
        }
        .navigationTitle("Stammdaten")
        .navigationBarTitleDisplayMode(.inline)
        .settingsError($errorMessage)
    }

    private func content(_ masterData: MasterDataEditor) -> some View {
        List {
            Section {
                SegmentedChoice(
                    options: [(Kind.units, "Fahrzeuge \(masterData.units.count)"), (.hospitals, "Kliniken \(masterData.hospitals.count)"), (.sections, "Abschnitte \(masterData.sections.count)")],
                    selection: $kind
                )
                .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.s, bottom: Spacing.s, trailing: Spacing.s))
                if isAdmin {
                    Button { showsRegions = true } label: {
                        Label("Region laden (Fahrzeuge, Kliniken)", systemImage: "arrow.down.circle")
                    }
                    .frame(minHeight: TouchTarget.minimum)
                } else {
                    Label("Nur Administratoren können Stammdaten ändern.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
            switch kind {
            case .units: unitList(masterData)
            case .hospitals: hospitalList(masterData)
            case .sections: sectionList(masterData)
            }
        }
        .searchable(text: $search, prompt: "Suchen")
        .toolbar {
            if isAdmin, kind != .sections {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if kind == .units {
                            editingUnit = MasterUnit(callsign: "", type: .rtw)
                        } else {
                            editingHospital = MasterHospital(name: "")
                        }
                    } label: {
                        Label("Neu", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $editingUnit) { unit in
            MasterUnitEditor(unit: unit, isNew: !masterData.units.contains { $0.id == unit.id }) { edited in
                try masterData.upsertUnit(edited)
            }
        }
        .sheet(item: $editingHospital) { hospital in
            MasterHospitalEditor(hospital: hospital, isNew: !masterData.hospitals.contains { $0.id == hospital.id }) { edited in
                try masterData.upsertHospital(edited)
            }
        }
        .sheet(isPresented: $showsRegions) {
            RegionImportSheet(masterData: masterData)
        }
    }

    private func matches(_ text: String) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: Listen

    @ViewBuilder
    private func unitList(_ masterData: MasterDataEditor) -> some View {
        let units = masterData.units.filter { matches("\($0.callsign) \($0.typeDisplayName)") }
        Section {
            if units.isEmpty { Text(masterData.units.isEmpty ? "Noch keine Fahrzeuge." : "Keines passt.").foregroundStyle(.secondary) }
            ForEach(units) { unit in
                Button { if isAdmin { editingUnit = unit } } label: {
                    HStack(spacing: Spacing.m) {
                        Text(unit.typeDisplayName).font(.subheadline.weight(.heavy)).frame(width: 56, alignment: .leading)
                        Text(unit.callsign).foregroundStyle(.primary)
                        Spacer()
                        if let crew = unit.crewCount { Text("\(crew) Pers.").foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: TouchTarget.minimum)
                }
                .swipeActions {
                    if isAdmin {
                        Button("Löschen", role: .destructive) { run { try masterData.removeUnit(unit.id) } }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hospitalList(_ masterData: MasterDataEditor) -> some View {
        let hospitals = masterData.hospitals.filter { matches("\($0.name) \($0.city)") }
        Section {
            if hospitals.isEmpty { Text(masterData.hospitals.isEmpty ? "Noch keine Kliniken." : "Keine passt.").foregroundStyle(.secondary) }
            ForEach(hospitals) { hospital in
                Button { if isAdmin { editingHospital = hospital } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hospital.name).foregroundStyle(.primary)
                        Text([hospital.address, hospital.city].filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: TouchTarget.minimum, alignment: .leading)
                }
                .swipeActions {
                    if isAdmin {
                        Button("Löschen", role: .destructive) { run { try masterData.removeHospital(hospital.id) } }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionList(_ masterData: MasterDataEditor) -> some View {
        Section {
            if isAdmin {
                HStack {
                    TextField("Neuer Abschnitt, z. B. Patientenablage", text: $newSection)
                        .onSubmit { addSection(masterData) }
                    Button("Hinzufügen") { addSection(masterData) }
                        .disabled(newSection.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(masterData.sections.filter { matches($0.name) }) { section in
                HStack {
                    Text(section.name)
                    Spacer()
                    if section.isInitial {
                        Text("Initial").font(.caption.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(ActionFill.primary, in: Capsule())
                    }
                }
                .frame(minHeight: TouchTarget.minimum)
                .contextMenu {
                    if isAdmin {
                        Button(section.isInitial ? "Kein Initialabschnitt" : "Als Initialabschnitt") {
                            run { try masterData.setInitialSection(section.isInitial ? nil : section.id) }
                        }
                    }
                }
                .swipeActions {
                    if isAdmin {
                        Button("Löschen", role: .destructive) { run { try masterData.removeSection(section.id) } }
                    }
                }
            }
        } footer: {
            Text("Vorschläge beim Anlegen eines Abschnitts. Der Initialabschnitt nimmt neue Einheiten auf (lange drücken).")
        }
    }

    private func addSection(_ masterData: MasterDataEditor) {
        let name = newSection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run { try masterData.save(name) }
        newSection = ""
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = ErrorText.message(for: error) }
    }
}

/// Fahrzeug bearbeiten.
struct MasterUnitEditor: View {
    let isNew: Bool
    let onSave: (MasterUnit) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var unit: MasterUnit
    @State private var crewText: String
    @State private var errorMessage: String?

    init(unit: MasterUnit, isNew: Bool, onSave: @escaping (MasterUnit) throws -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _unit = State(initialValue: unit)
        _crewText = State(initialValue: unit.crewCount.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Funkrufname") {
                    TextField("z. B. RK SWFT 71/1", text: $unit.callsign).autocorrectionDisabled()
                }
                Section("Typ") {
                    FlowLayout(spacing: Spacing.s) {
                        ForEach(UnitType.allCases) { candidate in
                            ChoiceChip(candidate.shortName, isSelected: unit.type == candidate, minHeight: TouchTarget.minimum) { unit.type = candidate }
                        }
                    }
                    TextField("Eigene Typbezeichnung (optional, z. B. HVO)", text: Binding(
                        get: { unit.typeLabel ?? "" },
                        set: { unit.typeLabel = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ))
                }
                Section("Besatzung") {
                    TextField("Personen (optional)", text: $crewText).keyboardType(.numberPad)
                }
            }
            .navigationTitle(isNew ? "Neues Fahrzeug" : "Fahrzeug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern", action: save).fontWeight(.bold) }
            }
            .settingsError($errorMessage)
        }
    }

    private func save() {
        var edited = unit
        edited.crewCount = Int(crewText.trimmingCharacters(in: .whitespaces))
        do {
            try onSave(edited)
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Klinik bearbeiten.
struct MasterHospitalEditor: View {
    let isNew: Bool
    let onSave: (MasterHospital) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hospital: MasterHospital
    @State private var errorMessage: String?

    init(hospital: MasterHospital, isNew: Bool, onSave: @escaping (MasterHospital) throws -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _hospital = State(initialValue: hospital)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("z. B. Leopoldina Schweinfurt", text: $hospital.name) }
                Section("Anschrift") {
                    TextField("Straße", text: $hospital.address)
                    TextField("Ort", text: $hospital.city)
                }
                Section("Kontakt") {
                    TextField("Telefon", text: $hospital.phone).keyboardType(.phonePad)
                    TextField("E-Mail", text: $hospital.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(isNew ? "Neue Klinik" : "Klinik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        do {
                            try onSave(hospital)
                            dismiss()
                        } catch {
                            errorMessage = ErrorText.message(for: error)
                        }
                    }
                    .fontWeight(.bold)
                }
            }
            .settingsError($errorMessage)
        }
    }
}
