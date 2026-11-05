import SwiftUI
import ELRDDomain
import ELRDStore

/// Patient bearbeiten – alles auf einer Seite, ohne Untermenüs (Mockup Bildschirm 6).
///
/// Oben Nummer, Name und Sichtung; darunter die Spalten Person, Zustand und
/// Transport (auf dem iPad mini untereinander). Gespeichert wird automatisch.
struct PatientDetailView: View {
    let store: MissionStore
    let patientID: PatientID
    /// Reihenfolge der aktuellen Liste für „vorheriger/nächster Patient“.
    let order: [PatientID]
    let onNavigate: (PatientID) -> Void
    var catalogs: PatientCatalogs = .empty

    @Environment(\.dismiss) private var dismiss
    @State private var form: PatientEditForm?
    @State private var saveState: SaveState = .saved
    @State private var confirmsDelete = false
    @State private var showsInjuries = false
    /// Körperteil, mit dem die Verletzungsauswahl öffnet (Tipp in die kleine Grafik).
    @State private var injuryStartSpot: BodySpot?
    @State private var showsHospitals = false
    @State private var confirmsRelease = false
    /// Kreislauf und „intubiert“ untereinander, wenn die Spalte schmal ist.
    @State private var stacksCirculation = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case number, dispatch, firstName, lastName, birthDate, age, features, notes }

    enum SaveState: Equatable {
        case saved, pending
        case failed(String)
    }

    private var patient: Patient? {
        store.state.patients.first { $0.id == patientID && !$0.metadata.isDeleted }
    }

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }

    var body: some View {
        Group {
            if let patient {
                content(patient)
            } else {
                ContentUnavailableView("Patient nicht vorhanden", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Der Patient wurde gelöscht."))
            }
        }
        .background(Surface.canvas)
        .onAppear {
            if form == nil, let patient { form = PatientEditForm(patient: patient) }
            // Nur für CI-Bildschirmfotos: Verletzungsauswahl direkt öffnen.
            if AppLaunchOptions.current.demoScreen == .injuries {
                injuryStartSpot = BodySpot(.unterschenkel, .rechts)
                showsInjuries = true
            }
        }
        // Automatisch speichern, kurz nachdem nicht mehr getippt wird.
        .task(id: form) {
            guard form != nil else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { save() }
        }
        .onChange(of: form) { old, new in
            if old != nil, saveState != .pending { saveState = .pending }
        }
        .onDisappear { save() }
    }

    // MARK: Aufbau

    private func content(_ patient: Patient) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let isWide = width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(patient)
                    triageRow(patient)
                    if width >= 1150 {
                        // iPad Pro quer: drei Spalten wie im Mockup.
                        HStack(alignment: .top, spacing: Spacing.l) {
                            personCard(patient)
                            conditionCard
                            transportCard(patient)
                        }
                    } else {
                        // Schmaler: Person über die volle Breite, darunter Zustand und Transport.
                        personCard(patient)
                        let rest = width >= 700
                            ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.l))
                            : AnyLayout(VStackLayout(spacing: Spacing.l))
                        rest {
                            conditionCard
                            transportCard(patient)
                        }
                    }
                }
                .padding(isWide ? Spacing.xl : Spacing.l)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: width, initial: true) { _, newWidth in
                // Spaltenbreite der Zustandskarte (Rand und Abstand grob abgezogen).
                let columns: CGFloat = newWidth >= 1150 ? 3 : newWidth >= 700 ? 2 : 1
                stacksCirculation = (newWidth - 80) / columns < 420
            }
        }
        .navigationTitle("Patient \(patient.number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(patient) }
        .confirmationDialog("Patient \(patient.number) löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Patient löschen", role: .destructive) { delete() }
        } message: {
            Text("Die Nummer bleibt vergeben. Der Patient verschwindet aus Liste und Zählern.")
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ patient: Patient) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            saveIndicator
            let index = order.firstIndex(of: patientID)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(index.map { $0 == 0 } ?? true)
                .accessibilityLabel("Vorheriger Patient")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(index.map { $0 >= order.count - 1 } ?? true)
                .accessibilityLabel("Nächster Patient")
            Menu {
                Button("Patient löschen …", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    .disabled(!canEdit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Weitere Aktionen")
        }
    }

    @ViewBuilder private var saveIndicator: some View {
        switch saveState {
        case .saved:
            Label("gespeichert", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.subheadline).foregroundStyle(.secondary)
        case .pending:
            Label("…", systemImage: "pencil").labelStyle(.iconOnly).foregroundStyle(.secondary)
        case .failed:
            Label("nicht gespeichert", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon)
                .font(.subheadline).foregroundStyle(.orange)
        }
    }

    private func header(_ patient: Patient) -> some View {
        HStack(spacing: Spacing.l) {
            Text(patient.number.description)
                .font(.title.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(Color.onTriage(patient.triage))
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
                .background(Color.triage(patient.triage), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(patient.fullName.isEmpty ? "Name unbekannt" : patient.fullName)
                    .font(.title.weight(.heavy))
                    .foregroundStyle(patient.fullName.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(subtitle(patient))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func subtitle(_ patient: Patient) -> String {
        var parts: [String] = []
        if let ils = patient.dispatchPatientNumber, !ils.isEmpty { parts.append("ILS \(ils)") }
        if let features = patient.identifyingFeatures, !features.isEmpty { parts.append(features) }
        parts.append("seit \(patient.metadata.createdAt.formatted(date: .omitted, time: .shortened))")
        parts.append(patient.status.displayName)
        return parts.joined(separator: " · ")
    }

    private func triageRow(_ patient: Patient) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: Spacing.s)], spacing: Spacing.s) {
            ForEach(Self.triageOrder, id: \.self) { category in
                TriageChoiceButton(category: category, isSelected: patient.triage == category) {
                    setTriage(category)
                }
                .disabled(!canEdit)
            }
        }
    }

    static let triageOrder: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .unverletzt, .ungesichtet, .verstorben]

    // MARK: Person

    @ViewBuilder
    private func personCard(_ patient: Patient) -> some View {
        if let binding = Binding($form) {
            let now = Date()
            let problems = binding.wrappedValue.problems(now: now)
            let hints = binding.wrappedValue.duplicateHints(patientID: patientID, among: store.state.patients)
            DetailCard(title: "Person") {
                HStack(alignment: .top, spacing: Spacing.s) {
                    field("Nr.", text: binding.number, field: .number)
                        .textInputAutocapitalization(.characters)
                        .frame(width: 110)
                    field("ILS-Patientennummer", text: binding.dispatchNumber, field: .dispatch)
                        .textInputAutocapitalization(.characters)
                }
                HStack(alignment: .top, spacing: Spacing.s) {
                    field("Vorname", text: binding.firstName, field: .firstName).textContentType(.givenName)
                    field("Nachname", text: binding.lastName, field: .lastName).textContentType(.familyName)
                }
                HStack(alignment: .top, spacing: Spacing.s) {
                    field("Geburtsdatum", prompt: "TT.MM.JJJJ", text: binding.birthDate, field: .birthDate)
                        .keyboardType(.numbersAndPunctuation)
                    if binding.wrappedValue.birthDate.trimmingCharacters(in: .whitespaces).isEmpty {
                        field("oder Alter ca.", prompt: "Jahre", text: binding.age, field: .age)
                            .keyboardType(.numberPad)
                            .frame(width: 130)
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Alter").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(patient.age(at: now).map { "\($0) J" } ?? "–")
                                .font(.title3.monospacedDigit())
                                .frame(minHeight: TouchTarget.comfortable)
                        }
                        .frame(width: 130, alignment: .leading)
                    }
                }
                HStack(spacing: Spacing.s) {
                    SegmentedChoice(
                        options: [(Gender.maennlich, "männlich"), (.weiblich, "weiblich"), (.unklar, "unklar")],
                        selection: binding.gender
                    )
                    Toggle(isOn: binding.isChild) { Text("Kind").font(.headline) }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(minHeight: TouchTarget.comfortable)
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Erkennungsmerkmale / Fundort").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("z. B. Fahrer Pkw rot, Beifahrersitz, blaue Jacke", text: binding.identifyingFeatures, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focus, equals: .features)
                        .inputBox()
                }
                ForEach(problems, id: \.message) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                ForEach(hints, id: \.self) { hint in
                    Label(hint, systemImage: "info.circle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .disabled(!canEdit)
        }
    }

    // MARK: Zustand

    @ViewBuilder
    private var conditionCard: some View {
        if let binding = Binding($form), let patient {
            DetailCard(title: "Zustand") {
                circulationSection(patient)
                ivenaSection(patient)
                injuriesSection(patient)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Notiz").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Maßnahmen, Medikamente, Besonderheiten …", text: binding.notes, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($focus, equals: .notes)
                        .inputBox()
                }
            }
            .disabled(!canEdit)
            .sheet(isPresented: $showsInjuries) {
                InjuryPickerView(
                    catalog: catalogs.injuries,
                    injuries: self.patient?.injuries ?? [],
                    initialSpot: injuryStartSpot,
                    onAdd: addInjury,
                    onRemove: removeInjury
                )
                .largeSheet()
            }
        }
    }

    /// Kreislauf (3 Zustände) und intubiert – ein Tipp speichert sofort.
    private func circulationSection(_ patient: Patient) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Kreislauf").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            // Schmale Spalte (iPad mini hoch): „intubiert“ unter den Kreislauf, damit nichts gekürzt wird.
            let layout = stacksCirculation
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
                : AnyLayout(HStackLayout(spacing: Spacing.s))
            layout {
                circulationChoice(patient)
                intubatedToggle(patient)
            }
        }
    }

    private func circulationChoice(_ patient: Patient) -> some View {
        SegmentedChoice(
            options: [(CirculationState.unbekannt, "unbekannt"), (.stabil, "stabil"), (.instabil, "instabil")],
            selection: patientBinding(patient, \.circulation)
        )
    }

    private func intubatedToggle(_ patient: Patient) -> some View {
        Toggle(isOn: patientBinding(patient, \.isIntubated)) { Text("intubiert").font(.headline) }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.large)
    }

    /// IVENA: RMI, Priorität, PZC; bei Priorität 1 zusätzlich der ABCD-Status.
    private func ivenaSection(_ patient: Patient) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("IVENA").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                let code = patient.allocationCode(at: Date())
                Text("PZC ").font(.subheadline).foregroundStyle(.secondary)
                    + Text(code.description).font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(code.isComplete ? Color.primary : Color.secondary)
            }
            .accessibilityElement(children: .combine)
            RMIField(catalog: catalogs.rmi, code: patient.rmiCode) { code in
                update { $0.rmiCode = code }
            }
            SegmentedChoice(
                options: [(TreatmentPriority.sofortigeIntervention, "1 sofort"), (.stationaereAufnahmeWahrscheinlich, "2 stationär"), (.vermutlichAmbulant, "3 ambulant")],
                selection: patientBinding(patient, \.treatmentPriority)
            )
            if patient.treatmentPriority == .sofortigeIntervention {
                Text("ABCD-Status · Info für die Klinik").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ABCDPicker(status: patient.abcd ?? ABCDStatus()) { letter, level in
                    update { patient in
                        var status = patient.abcd ?? ABCDStatus()
                        status[letter] = level
                        patient.abcd = status.isEmpty ? nil : status
                    }
                }
            }
        }
    }

    /// Bindung an ein Patientenfeld, die jede Änderung sofort speichert.
    private func patientBinding<Value: Equatable>(_ patient: Patient, _ keyPath: WritableKeyPath<Patient, Value>) -> Binding<Value> {
        Binding(
            get: { self.patient?[keyPath: keyPath] ?? patient[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    /// Speichert eine sofortige Änderung (Auswahlknöpfe) über `EditPatient`.
    private func update(_ change: @escaping (inout Patient) -> Void) {
        do {
            try store.perform(EditPatient(patientID: patientID, change))
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// Verletzungen: Liste mit Entfernen, „+ Verletzung“ öffnet die Auswahl.
    private func injuriesSection(_ patient: Patient) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Verletzungen").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Spacing.m) {
                // Kleine Körpergrafik mit Markierungen; Tipp öffnet die Auswahl an dieser Stelle.
                if !patient.injuries.isEmpty && !stacksCirculation {
                    BodyDiagramView(
                        selection: nil,
                        counts: BodyPart.counts(for: patient.injuries),
                        onSelect: canEdit ? { openInjuries(at: $0) } : nil,
                        showsLabels: false
                    )
                    .frame(width: 96, height: 168)
                }
                VStack(spacing: Spacing.s) {
                    ForEach(patient.injuries) { injury in
                        InjuryRow(injury: injury, onRemove: canEdit ? { removeInjury(injury.id) } : nil)
                    }
                }
            }
            Button { openInjuries(at: nil) } label: {
                Label(patient.injuries.isEmpty ? "Verletzung erfassen" : "Weitere Verletzung", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func openInjuries(at spot: BodySpot?) {
        injuryStartSpot = spot
        showsInjuries = true
    }

    // MARK: Transport

    private func transportCard(_ patient: Patient) -> some View {
        DetailCard(title: "Transport") {
            switch patient.outcome {
            case .transported(let startedAt):
                outcomeSummary(
                    title: "Im Transport seit \(startedAt.formatted(date: .omitted, time: .shortened))",
                    detail: [assignedUnitNames(patient), patient.destination?.name].compactMap { $0 }.joined(separator: " → "),
                    symbol: "arrow.right.circle.fill",
                    undoTitle: "Transport zurücknehmen"
                )
                destinationSection(patient)
            case .released(let at, let handledBy):
                outcomeSummary(
                    title: "Vor Ort entlassen um \(at.formatted(date: .omitted, time: .shortened))",
                    detail: handledBy.isEmpty ? "" : "versorgt durch \(handledBy.joined(separator: ", "))",
                    symbol: "checkmark.circle.fill",
                    undoTitle: "Entlassung zurücknehmen"
                )
            case nil:
                unitSection(patient)
                destinationSection(patient)
                transportActions(patient)
            }
        }
        .disabled(!canEdit)
        .sheet(isPresented: $showsHospitals) {
            HospitalPickerView(
                choices: hospitalChoices(patient),
                current: patient.destination,
                onSelect: { hospital in perform(SetDestination(patientID: patientID, hospital: hospital)) }
            )
            .largeSheet()
        }
        .confirmationDialog("Patient \(patient.number) vor Ort entlassen?", isPresented: $confirmsRelease, titleVisibility: .visible) {
            Button("Entlassen") { perform(ReleasePatient(patientID: patientID, clearDestination: true)) }
            if patient.destination != nil {
                Button("Entlassen, Zielklinik behalten") { perform(ReleasePatient(patientID: patientID, clearDestination: false)) }
            }
        } message: {
            Text("Zugeordnete Einheiten werden frei; ihre Namen bleiben am Patienten vermerkt.")
        }
    }

    /// Einheiten als große Knöpfe: Tipp ordnet zu bzw. löst die Zuordnung.
    private func unitSection(_ patient: Patient) -> some View {
        let choices = UnitChoice.ordered(units: store.state.units, patients: store.state.patients, for: patientID)
        let hasUnit = choices.contains(where: \.isAssigned)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(hasUnit ? "Einheit" : "Einheit – noch keine zugewiesen")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hasUnit ? Color.secondary : Color.orange)
            if choices.isEmpty {
                Text("Im Einsatz sind noch keine Einheiten. Unter „Einheiten“ hinzufügen.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: Spacing.s) {
                    ForEach(choices) { choice in
                        ChoiceChip(choice.label, isSelected: choice.isAssigned, minHeight: 52, background: Surface.elevated) {
                            if choice.isAssigned {
                                perform(UnassignUnit(patientID: patientID, unitID: choice.id))
                            } else {
                                perform(AssignUnit(patientID: patientID, unitID: choice.id))
                            }
                        }
                        .opacity(choice.isFree || choice.isAssigned ? 1 : 0.75)
                    }
                }
            }
        }
    }

    /// Zielklinik: gewählte mit „ändern“, sonst die ersten Vorschläge und „Alle …“.
    private func destinationSection(_ patient: Patient) -> some View {
        let suggestions = Array(hospitalChoices(patient).prefix(3))
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Zielklinik").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let destination = patient.destination {
                Button { showsHospitals = true } label: {
                    HStack {
                        Text(destination.name).font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Text("ändern").font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: TouchTarget.comfortable)
                    .background(ActionFill.selected, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                SegmentedChoice(
                    options: [(HospitalRegistrationState.nichtAngefragt, "nicht angefragt"), (.angefragt, "angefragt"), (.angemeldet, "angemeldet")],
                    selection: Binding(
                        get: { patient.registrationState },
                        set: { perform(SetRegistration(patientID: patientID, state: $0)) }
                    )
                )
            } else {
                FlowLayout(spacing: Spacing.s) {
                    ForEach(suggestions) { choice in
                        ChoiceChip(
                            choice.distanceText.map { "\(choice.hospital.name) · \($0)" } ?? choice.hospital.name,
                            isSelected: false, minHeight: 52, background: Surface.elevated
                        ) {
                            perform(SetDestination(patientID: patientID, hospital: choice.hospital.snapshot))
                        }
                    }
                    Button("Alle Kliniken …") { showsHospitals = true }
                        .font(.headline)
                        .frame(minHeight: 52)
                }
            }
            Text("Schockraum").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            SegmentedChoice(
                options: [(TraumaRoom.none, "keiner"), (.a, "A"), (.b, "B")],
                selection: patientBinding(patient, \.traumaRoom)
            )
        }
    }

    /// „Transport starten“ groß, „Vor Ort entlassen“ daneben bzw. darunter.
    private func transportActions(_ patient: Patient) -> some View {
        let canStart = patient.hasTransportUnit(in: store.state.units)
        return VStack(spacing: Spacing.s) {
            Button { perform(StartTransport(patientID: patientID)) } label: {
                VStack(spacing: 2) {
                    Label("Transport starten", systemImage: "arrow.right.circle.fill").font(.title3.weight(.heavy))
                    if !canStart {
                        Text(patient.unitIDs.isEmpty ? "zuerst Einheit wählen" : "zuerst RTW, KTW oder RTH wählen")
                            .font(.caption.weight(.semibold))
                    }
                }
                .foregroundStyle(canStart ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                .background(canStart ? ActionFill.primary : Surface.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            Button { confirmsRelease = true } label: {
                Label("Vor Ort entlassen", systemImage: "figure.walk")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func outcomeSummary(title: String, detail: String, symbol: String, undoTitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(title, systemImage: symbol).font(.title3.weight(.bold))
            if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            Button(undoTitle) { perform(ResetOutcome(patientID: patientID)) }
                .font(.headline)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    private func assignedUnitNames(_ patient: Patient) -> String? {
        let names = store.state.units.filter { patient.unitIDs.contains($0.id) }.map(\.displayName)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private func hospitalChoices(_ patient: Patient) -> [HospitalChoice] {
        HospitalChoice.ordered(hospitals: catalogs.hospitals, patients: store.state.patients, near: store.state.mission.coordinate)
    }

    /// Führt einen Befehl aus; Fehler erscheinen oben als „nicht gespeichert“.
    private func perform<Command: MissionCommand>(_ command: Command) {
        do {
            _ = try store.perform(command)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    // MARK: Bausteine

    private func field(_ label: String, prompt: String? = nil, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt ?? ""))
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .submitLabel(.next)
                .onSubmit { save() }
                .inputBox()
        }
    }

    // MARK: Aktionen

    private func save() {
        guard var current = form, patient != nil else { return }
        let now = Date()
        guard current.hasChanges(now: now) else {
            if saveState == .pending { saveState = .saved }
            return
        }
        let snapshot = current
        do {
            let updated = try store.perform(EditPatient(patientID: patientID) { snapshot.apply(to: &$0, now: now) })
            current.markSaved(updated, now: now)
            form = current
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func addInjury(_ injury: Injury) {
        do {
            try store.perform(AddInjury(patientID: patientID, injury: injury))
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func removeInjury(_ id: InjuryID) {
        do {
            try store.perform(RemoveInjury(patientID: patientID, injuryID: id))
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func setTriage(_ category: Sichtungskategorie) {
        do {
            try store.perform(SetTriage(patientID: patientID, triage: category))
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func step(_ offset: Int) {
        guard let index = order.firstIndex(of: patientID), order.indices.contains(index + offset) else { return }
        save()
        onNavigate(order[index + offset])
    }

    private func delete() {
        do {
            try store.perform(DeletePatient(patientID: patientID))
            form = nil
            dismiss()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Bausteine

/// Karte mit Überschrift für die Spalten des Patienten.
struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(title).font(.title3.weight(.bold))
            content
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Hinweis auf einen später gebauten Teil.
struct PlannedHint: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "hammer")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// Segmentierte Auswahl mit großen Feldern (statt des kleinen System-Pickers).
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.subheadline.weight(selection == value ? .heavy : .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selection == value ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum + 4)
                        .background(selection == value ? Surface.card : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(Spacing.xs)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    /// Eingabefeld-Optik in Karten.
    func inputBox() -> some View {
        padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: TouchTarget.comfortable)
            .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Großer SK-Auswahlknopf: gewählt mit kräftigem Rand, sonst abgeschwächt.
struct TriageChoiceButton: View {
    let category: Sichtungskategorie
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if isSelected { Image(systemName: "checkmark.circle.fill") }
                Text(category == .ungesichtet || category == .unverletzt || category == .verstorben ? category.displayName.lowercased() : category.shortName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
                .font(category.shortName.count > 3 ? .headline.weight(.heavy) : .title3.weight(.heavy))
                .padding(.horizontal, Spacing.xs)
                .foregroundStyle(Color.onTriage(category))
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.triage(category), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary, lineWidth: isSelected ? 5 : (TriageBadge.needsOutline(category) ? 1 : 0))
                }
                // Farben immer kräftig (lesbar); gewählt = dicker Rand + Häkchen.
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
