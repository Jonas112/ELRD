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
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @State private var form: PatientEditForm?
    @State private var saveState: SaveState = .saved
    @State private var confirmsDelete = false
    @State private var showsInjuries = false
    /// Körperteil, mit dem die Verletzungsauswahl öffnet (Tipp in die kleine Grafik).
    @State private var injuryStartSpot: BodySpot?
    @State private var showsHospitals = false
    @State private var showsUnits = false
    @State private var editsTag = false
    /// Seltene Angaben (Nummer, ILS, Alter, Geschlecht, Merkmale) eingeklappt.
    @State private var showsPersonDetails = false
    /// IVENA eingeklappt; Zusammenfassung mit PZC bleibt sichtbar.
    @State private var showsIVENA = false
    /// ATMIST-Übergabe (Schritt 97).
    @State private var showsHandover = false
    /// Geführte Sichtung (Schritt 87).
    @State private var showsTriageGuide = AppLaunchOptions.current.demoScreen == .triageGuide
    @State private var tagText = ""
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
            if AppLaunchOptions.current.demoScreen == .unitPicker { showsUnits = true }
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
                Button("Übergabe (ATMIST) …", systemImage: "text.bubble") { showsHandover = true }
                Button("Anhängekarte zuordnen …", systemImage: "barcode") {
                    tagText = store.state.patients.first { $0.id == patientID }?.tagNumber ?? ""
                    editsTag = true
                }
                .disabled(!canEdit)
                Button("Patient löschen …", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    .disabled(!canEdit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Weitere Aktionen")
            .sheet(isPresented: $showsHandover) {
                ShareTextSheet(
                    title: "Übergabe \(patient.number)",
                    text: ATMISTHandover.text(patient: patient, mission: store.state.mission, units: store.state.units, now: Date()),
                    subject: "Übergabe Patient \(patient.number)",
                    footnote: "ATMIST: Alter, Zeit, Mechanismus, Verletzungen, Zeichen, Therapie. Enthält den Namen, falls bekannt – nur an Klinik oder Transportbesatzung weitergeben."
                )
                .largeSheet()
            }
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
        if let tag = patient.tagNumber { parts.append("Karte \(tag)") }
        if let ils = patient.dispatchPatientNumber, !ils.isEmpty { parts.append("ILS \(ils)") }
        if let features = patient.identifyingFeatures, !features.isEmpty { parts.append(features) }
        parts.append("seit \(patient.metadata.createdAt.formatted(date: .omitted, time: .shortened))")
        parts.append(patient.status.displayName)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func triageButtons(_ patient: Patient, algorithm: TriageAlgorithm) -> some View {
        Button { showsTriageGuide = true } label: {
            Label("Sichtungshilfe \(algorithm.displayName)", systemImage: "list.bullet.clipboard")
                .font(.headline)
                .frame(minHeight: TouchTarget.minimum)
        }
        .buttonStyle(.bordered)
        if patient.triage.isTriaged, patient.outcome == nil {
            Button {
                do { try store.perform(ConfirmTriage(patientID: patientID)) } catch { saveState = .failed(ErrorText.message(for: error)) }
            } label: {
                Label("Nachsichtung: bleibt \(patient.triage.shortName)", systemImage: "checkmark.circle")
                    .font(.headline)
                    .frame(minHeight: TouchTarget.minimum)
            }
            .buttonStyle(.bordered)
        }
    }

    private func triageRow(_ patient: Patient) -> some View {
        let algorithm = appSettings?.settings.triageAlgorithm ?? .mstart
        return VStack(alignment: .leading, spacing: Spacing.s) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: Spacing.s)], spacing: Spacing.s) {
                ForEach(Self.triageOrder, id: \.self) { category in
                    TriageChoiceButton(category: category, isSelected: patient.triage == category) {
                        setTriage(category)
                    }
                    .disabled(!canEdit)
                }
            }
            // Schritt 95: zuletzt gesichtet, Nachsichtung bestätigen.
            if let last = patient.lastTriagedAt, patient.outcome == nil {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let minutes = max(0, Int(context.date.timeIntervalSince(last) / 60))
                    let limit = (appSettings?.settings.reminders ?? ReminderSettings()).retriageMinutes(for: patient.triage)
                    Label("Zuletzt gesichtet \(last.formatted(date: .omitted, time: .shortened)) Uhr (vor \(minutes) min)", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(limit > 0 && minutes >= limit ? .bold : .regular))
                        .foregroundStyle(limit > 0 && minutes >= limit ? Color.orange : Color.secondary)
                }
            }
            if canEdit {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.s) { triageButtons(patient, algorithm: algorithm) }
                    VStack(alignment: .leading, spacing: Spacing.s) { triageButtons(patient, algorithm: algorithm) }
                }
            }
        }
        .sheet(isPresented: $showsTriageGuide) {
            TriageGuideSheet(store: store, patientID: patientID, algorithm: algorithm)
                .largeSheet()
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
                    field("Vorname", text: binding.firstName, field: .firstName).textContentType(.givenName)
                    field("Nachname", text: binding.lastName, field: .lastName).textContentType(.familyName)
                }
                disclosure(
                    isExpanded: $showsPersonDetails,
                    summary: personSummary(patient, now: now),
                    title: "Nr., ILS, Alter, Geschlecht, Merkmale"
                )
                if showsPersonDetails {
                HStack(alignment: .top, spacing: Spacing.s) {
                    field("Nr.", text: binding.number, field: .number)
                        .textInputAutocapitalization(.characters)
                        .frame(width: 110)
                    field("ILS-Patientennummer", text: binding.dispatchNumber, field: .dispatch)
                        .textInputAutocapitalization(.characters)
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
                            Text("Alter").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erkennungsmerkmale / Fundort").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("z. B. Fahrer Pkw rot, Beifahrersitz, blaue Jacke", text: binding.identifyingFeatures, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focus, equals: .features)
                        .inputBox()
                }
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
                // IVENA lässt sich in den Einstellungen ausblenden (Schritt 49).
                if appSettings?.settings.showsIVENA ?? true { ivenaSection(patient) }
                injuriesSection(patient)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Notiz").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            Text("Kreislauf").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            let code = patient.allocationCode(at: Date())
            Button { withAnimation(.snappy) { showsIVENA.toggle() } } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("IVENA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("PZC ").font(.subheadline).foregroundStyle(.secondary)
                        + Text(code.description).font(.title3.weight(.heavy).monospacedDigit())
                            .foregroundStyle(code.isComplete ? Color.primary : Color.secondary)
                    Image(systemName: showsIVENA ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: TouchTarget.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(showsIVENA ? "Einklappen" : "RMI, Dringlichkeit und ABCD bearbeiten")
            if showsIVENA || patient.treatmentPriority == .sofortigeIntervention {
            RMIField(catalog: catalogs.rmi, code: patient.rmiCode) { code in
                update { $0.rmiCode = code }
            }
            SegmentedChoice(
                options: [(TreatmentPriority.sofortigeIntervention, "1 sofort"), (.stationaereAufnahmeWahrscheinlich, "2 stationär"), (.vermutlichAmbulant, "3 ambulant")],
                selection: patientBinding(patient, \.treatmentPriority),
                tint: { Color.treatmentPriority($0) }
            )
            }
            if patient.treatmentPriority == .sofortigeIntervention {
                Text("ABCD-Status · Info für die Klinik").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            saveState = .failed(ErrorText.message(for: error))
        }
    }

    /// Verletzungen: Liste mit Entfernen, „+ Verletzung“ öffnet die Auswahl.
    private func injuriesSection(_ patient: Patient) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Verletzungen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Spacing.m) {
                // Kleine Körpergrafik mit Markierungen; Tipp öffnet die Auswahl an dieser
                // Stelle – auch ohne erfasste Verletzung (Jonas).
                if !stacksCirculation {
                    BodyDiagramView(
                        selection: nil,
                        counts: BodyPart.counts(for: patient.injuries),
                        onSelect: canEdit ? { openInjuries(at: $0) } : nil,
                        showsLabels: false
                    )
                    .frame(width: 96, height: 168)
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if patient.injuries.isEmpty {
                        Text(canEdit && !stacksCirculation ? "Noch keine Verletzung. Körperteil antippen oder unten erfassen." : "Noch keine Verletzung.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                capacity: { hospital in HospitalCapacity(hospital: hospital, triage: patient.triage, state: store.state) },
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

    /// Transportmittel: nur zugeordnete Einheiten; Auswahl über die Liste (Knopf).
    private func unitSection(_ patient: Patient) -> some View {
        let assigned = store.state.units.filter { patient.unitIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Transportmittel").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            selectionButton(
                value: assigned.isEmpty ? nil : assigned.map { $0.isPlaceholder ? $0.displayName : "\($0.typeDisplayName) \($0.displayName)" }.joined(separator: ", "),
                placeholder: "Einheit wählen oder anlegen …",
                symbol: "box.truck",
                accent: nil
            ) { showsUnits = true }
        }
        .sheet(isPresented: $showsUnits) {
            UnitPickerSheet(store: store, patientID: patientID, masterUnits: catalogs.units)
                .largeSheet()
        }
        // Schritt 72: Nummer der Patientenanhängekarte (leer = entfernen).
        .alert("Anhängekarte", isPresented: $editsTag) {
            TextField("Kartennummer", text: $tagText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Sichern") { perform(SetPatientTag(patientID: patientID, tagNumber: tagText)) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Nummer oder Barcode-Inhalt der Karte. Leer lassen, um sie zu entfernen.")
        }
    }

    /// Zielklinik: nur die gewählte; Auswahl über die Liste (Knopf).
    private func destinationSection(_ patient: Patient) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Zielklinik").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            selectionButton(
                value: patient.destination?.name,
                placeholder: "Klinik wählen …",
                symbol: "cross.case",
                accent: patient.destination == nil ? nil : Color.registration(patient.registrationState)
            ) { showsHospitals = true }
            if patient.destination != nil {
                SegmentedChoice(
                    options: [(HospitalRegistrationState.nichtAngefragt, "nicht angefragt"), (.angefragt, "angefragt"), (.angemeldet, "angemeldet")],
                    selection: Binding(
                        get: { patient.registrationState },
                        set: { perform(SetRegistration(patientID: patientID, state: $0)) }
                    ),
                    tint: { Color.registration($0) }
                )
            }
            Text("Schockraum").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
        HospitalChoice.ordered(hospitals: catalogs.hospitals, patients: store.state.patients, near: store.state.mission.coordinate, quotas: store.state.mission.hospitalQuotas ?? [])
    }

    /// Führt einen Befehl aus; Fehler erscheinen oben als „nicht gespeichert“.
    private func perform<Command: MissionCommand>(_ command: Command) {
        do {
            _ = try store.perform(command)
        } catch {
            saveState = .failed(ErrorText.message(for: error))
        }
    }

    // MARK: Bausteine

    /// Eingeklappter Bereich: Zusammenfassung und „mehr“/„weniger“.
    private func disclosure(isExpanded: Binding<Bool>, summary: String, title: String) -> some View {
        Button { withAnimation(.snappy) { isExpanded.wrappedValue.toggle() } } label: {
            HStack(spacing: Spacing.s) {
                Text(summary.isEmpty ? title : summary)
                    .font(.subheadline)
                    .foregroundStyle(summary.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Spacing.s)
                Text(isExpanded.wrappedValue ? "weniger" : "mehr")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(minHeight: TouchTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded.wrappedValue ? "Einklappen" : "Weitere Angaben bearbeiten")
    }

    private func personSummary(_ patient: Patient, now: Date) -> String {
        var parts = ["Nr. \(patient.number)"]
        if let ils = patient.dispatchPatientNumber, !ils.isEmpty { parts.append("ILS \(ils)") }
        if let age = patient.age(at: now) { parts.append("\(age) J") }
        if patient.gender != .unklar { parts.append(patient.gender == .maennlich ? "männlich" : "weiblich") }
        if patient.isChild { parts.append("Kind") }
        if let features = patient.identifyingFeatures, !features.isEmpty { parts.append(features) }
        return parts.count == 1 ? "" : parts.joined(separator: " · ")
    }

    /// Gewählter Wert mit „ändern“ – oder ein Knopf, der die Auswahl öffnet.
    private func selectionButton(value: String?, placeholder: String, symbol: String, accent: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                if let accent {
                    Circle().fill(accent).frame(width: 12, height: 12).accessibilityHidden(true)
                } else {
                    Image(systemName: value == nil ? "plus.circle.fill" : symbol)
                        .font(.title3)
                        .foregroundStyle(value == nil ? ActionFill.primary : Color.secondary)
                }
                Text(value ?? placeholder)
                    .font(.headline)
                    .foregroundStyle(value == nil ? ActionFill.primary : Color.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Spacing.s)
                if value != nil {
                    Text("ändern").font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable, alignment: .leading)
            .background(value == nil ? Surface.elevated : ActionFill.selected, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if let accent {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "\($0), ändern" } ?? placeholder)
    }

    private func field(_ label: String, prompt: String? = nil, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            saveState = .failed(ErrorText.message(for: error))
        }
    }

    private func addInjury(_ injury: Injury) {
        do {
            try store.perform(AddInjury(patientID: patientID, injury: injury))
        } catch {
            saveState = .failed(ErrorText.message(for: error))
        }
    }

    private func removeInjury(_ id: InjuryID) {
        do {
            try store.perform(RemoveInjury(patientID: patientID, injuryID: id))
        } catch {
            saveState = .failed(ErrorText.message(for: error))
        }
    }

    private func setTriage(_ category: Sichtungskategorie) {
        do {
            try store.perform(SetTriage(patientID: patientID, triage: category))
        } catch {
            saveState = .failed(ErrorText.message(for: error))
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
            saveState = .failed(ErrorText.message(for: error))
        }
    }
}

// MARK: - Bausteine

/// Karte mit Überschrift für die Spalten des Patienten.
struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(title).font(.headline).foregroundStyle(.secondary)
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
    /// Fachliche Farbe je Wert (z. B. Anmeldestatus, IVENA-Dringlichkeit): gewählt
    /// voll gefüllt, sonst Schrift und Punkt in der Farbe.
    var tint: ((Value) -> Color)? = nil

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    segment(value, title)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(Spacing.xs)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func segment(_ value: Value, _ title: String) -> some View {
        let isSelected = selection == value
        if let color = tint?(value) {
            HStack(spacing: 6) {
                if !isSelected {
                    Circle().fill(color).frame(width: 10, height: 10)
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .heavy : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.white : color)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum + 4)
            .background(isSelected ? color : color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Text(title)
                .font(.subheadline.weight(isSelected ? .heavy : .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum + 4)
                .background(isSelected ? Surface.card : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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
