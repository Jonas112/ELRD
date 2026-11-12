import SwiftUI
import ELRDDomain

/// „Neuer Einsatz“: nur Stichwort, Einsatzart, Ort und optional Meldebild/ILS-Nummer.
/// Beginn ist „jetzt“, Einsatzleiter ist der angemeldete Benutzer.
struct NewMissionView: View {
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    let commanderName: String
    let start: (NewMissionForm) throws -> Void

    /// Lesbare Breite auf großen iPads; auf dem iPad mini füllt das Formular die Breite.
    static let contentWidth: CGFloat = 760

    @Environment(\.dismiss) private var dismiss
    @State private var form: NewMissionForm
    /// Ausgangsstand (für „ungespeicherte Eingaben“ beim Wischen).
    private let initialForm: NewMissionForm
    @State private var errorMessage: String?

    /// - Parameter initialForm: vorbefüllt, z. B. bei der Übernahme aus Alamos FE2 (Schritt 140).
    init(commanderName: String, initialForm: NewMissionForm? = nil, start: @escaping (NewMissionForm) throws -> Void) {
        self.commanderName = commanderName
        self.start = start
        let form = initialForm ?? Self.defaultForm()
        self.initialForm = form
        _form = State(initialValue: form)
    }

    private static func defaultForm() -> NewMissionForm {
        // Bildschirmfoto „Übung“: Lage schon gewählt.
        guard AppLaunchOptions.current.demoScreen == .newExercise, let bus = ExerciseScenario.scenario(id: "bus") else { return NewMissionForm() }
        var form = NewMissionForm()
        form.isExercise = true
        form.scenarioID = bus.id
        form.type = bus.type
        form.reason = bus.reason
        form.location = bus.location
        return form
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    if let alarm = form.alarm { importSection(alarm) }
                    stichwortSection
                    typeSection
                    locationSection
                    detailsSection
                    exerciseSection
                    Text("Beginn ist jetzt. Einsatzleiter: \(commanderName). Alles Weitere lässt sich im Einsatz ergänzen.")
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.xl)
                .frame(maxWidth: Self.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.canvas)
            .safeAreaInset(edge: .bottom) { startBar }
            .navigationTitle(form.alarm == nil ? "Neuer Einsatz" : "Einsatz übernehmen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .frame(minHeight: TouchTarget.minimum)
                }
            }
        }
        // Eingaben nicht durch versehentliches Wischen verlieren.
        .interactiveDismissDisabled(form != initialForm || form.alarm != nil)
    }

    // MARK: Abschnitte

    private var stichwortSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Alarmstichwort")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.m), count: 3), spacing: Spacing.m) {
                ForEach(Alarmstichwort.allCases) { stichwort in
                    ChoiceChip(stichwort.rawValue, isSelected: form.alarmstichwort == stichwort, minHeight: TouchTarget.large, fillsWidth: true) {
                        form.alarmstichwort = form.alarmstichwort == stichwort ? nil : stichwort
                    }
                }
                ChoiceChip("Ohne", isSelected: form.alarmstichwort == nil, minHeight: TouchTarget.large, fillsWidth: true) {
                    form.alarmstichwort = nil
                }
            }
            Text(stichwortHint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Schritt 140: Übernahme aus Alamos FE2 – was mitkommt.
    private func importSection(_ alarm: AlamosAlarm) -> some View {
        let data = alarm.data
        return VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Label("Aus Alamos FE2", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                if alarm.isTest { StatusChip("Test", color: .purple) }
                Spacer(minLength: 0)
                Text("Nr. \(alarm.externalId)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Meldebild, Ort und Einsatznummer sind übernommen. Der Alarmtext kommt ins Tagebuch, der Einsatzort auf die Karte.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !data.callsigns.isEmpty {
                Toggle(isOn: $form.importsVehicles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alarmierte Fahrzeuge übernehmen (\(data.callsigns.count))").font(.headline)
                        Text(data.callsigns.joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
                .onChange(of: form.importsVehicles) { _, imports in
                    // Echte Fahrzeuge statt Platzhalter: Stichwort nur ohne Fahrzeugübernahme vorschlagen.
                    if imports { form.alarmstichwort = nil } else if form.alarmstichwort == nil { form.alarmstichwort = data.alarmstichwort }
                }
            }
            if !data.patients.isEmpty {
                Toggle(isOn: $form.importsPatients) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gemeldete Patienten anlegen (\(data.patients.count))").font(.headline)
                        Text("Ungesichtet, Angaben der Leitstelle in der Notiz.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            }
        }
        .padding(Spacing.l)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var stichwortHint: String {
        guard let stichwort = form.alarmstichwort else { return "Ohne Stichwort werden keine Platzhalter angelegt." }
        return "Legt \(stichwort.summary) als Platzhalter an – später durch echte Fahrzeuge ersetzen."
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Einsatzart")
            FlowLayout(spacing: Spacing.s) {
                ForEach((appSettings?.settings ?? AppSettings()).missionTypeChoices(including: form.type), id: \.self) { type in
                    ChoiceChip(type.chipLabel, isSelected: form.type == type) {
                        choose(type)
                    }
                }
            }
            // Schritt 106: Vorlage der Einsatzart.
            if let template = appSettings?.settings.template(for: form.type), template.hasTemplate {
                Label(templateHint(template), systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Einsatzart wählen; ein Alarmstichwort der Vorlage wird übernommen, solange
    /// keines gewählt ist.
    private func choose(_ type: MissionType) {
        let previous = appSettings?.settings.template(for: form.type)?.alarmstichwort
        form.type = form.type == type ? nil : type
        let template = appSettings?.settings.template(for: form.type)
        if form.alarmstichwort == nil || form.alarmstichwort == previous {
            form.alarmstichwort = template?.alarmstichwort
        }
    }

    private func templateHint(_ template: MissionTypeSetting) -> String {
        var parts: [String] = []
        if let stichwort = template.alarmstichwort { parts.append("Stichwort \(stichwort.rawValue)") }
        let sections = template.templateSections
        if !sections.isEmpty { parts.append("Abschnitte " + sections.joined(separator: ", ")) }
        return "Vorlage: " + parts.joined(separator: " · ")
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Einsatzort")
            inputField("z. B. B 19, Höhe Ausfahrt Musterstadt", text: $form.location)
                .textContentType(.fullStreetAddress)
        }
    }

    private var detailsSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.l) {
                reasonField.frame(minWidth: 260)
                dispatchField.frame(minWidth: 260)
            }
            VStack(alignment: .leading, spacing: Spacing.xl) {
                reasonField
                dispatchField
            }
        }
    }

    /// Übung (Schritt 88): Kennzeichnung und optional eine vorbereitete Lage.
    private var exerciseSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Toggle(isOn: $form.isExercise) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Übung").font(.headline)
                    Text("Deutlich als Übung gekennzeichnet – in der App, im Bericht und in Mitteilungen.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .tint(.purple)
            .frame(minHeight: TouchTarget.comfortable)
            if form.isExercise {
                sectionLabel("Übungslage", optional: true)
                FlowLayout(spacing: Spacing.s) {
                    ChoiceChip("Ohne Lage", isSelected: form.scenarioID == nil) { form.scenarioID = nil }
                    ForEach(ExerciseScenario.all) { scenario in
                        ChoiceChip("\(scenario.name) (\(scenario.patients.count))", isSelected: form.scenarioID == scenario.id) {
                            choose(scenario)
                        }
                    }
                }
                if let scenario = form.scenarioID.flatMap(ExerciseScenario.scenario(id:)) {
                    Text("\(scenario.summary). Patienten kommen ungesichtet mit Befunden in der Notiz; die Auswertung steht unter Tagebuch › Verlauf.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Spacing.l)
        .background(Color.purple.opacity(form.isExercise ? 0.10 : 0), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func choose(_ scenario: ExerciseScenario) {
        form.scenarioID = scenario.id
        form.type = scenario.type
        if form.reason.isEmpty || ExerciseScenario.all.contains(where: { $0.reason == form.reason }) { form.reason = scenario.reason }
        if form.location.isEmpty || form.location == "Übungsgelände" { form.location = scenario.location }
    }

    private var reasonField: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("Meldebild", optional: true)
            inputField("z. B. 3 Pkw, eine Person eingeklemmt", text: $form.reason)
        }
    }

    private var dispatchField: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            sectionLabel("ILS-Einsatznummer", optional: true)
            inputField("Freitext", text: $form.dispatchNumber)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
    }

    private var startBar: some View {
        VStack(spacing: Spacing.s) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Button(action: startMission) {
                Label(form.alarm == nil ? "Einsatz starten" : "Übernehmen und starten", systemImage: "play.fill")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.large + 8)
                    .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.l)
        .background(.bar)
    }

    // MARK: Bausteine

    private func sectionLabel(_ title: String, optional: Bool = false) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(title).fontWeight(.semibold)
            if optional { Text("(optional)") }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }

    private func inputField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(.title3)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: TouchTarget.comfortable + 8)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func startMission() {
        errorMessage = nil
        do {
            try start(form)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

#Preview("Neuer Einsatz") {
    NewMissionView(commanderName: "Erika Beispiel") { _ in }
}
