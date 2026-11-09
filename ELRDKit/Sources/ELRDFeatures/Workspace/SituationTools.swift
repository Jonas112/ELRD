import SwiftUI
import ELRDDomain
import ELRDStore

// MARK: - Lagemeldung (Schritt 67)

/// Lagemeldung erstellen: Text aus den Daten, Lage und Gefahren ergänzen,
/// groß zum Vorlesen am Funk, dann ins Tagebuch.
struct SituationReportSheet: View {
    let store: MissionStore

    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var hazards: String
    @State private var text: String
    @State private var generated: String
    @State private var errorMessage: String?

    init(store: MissionStore) {
        self.store = store
        let mission = store.state.mission
        let initialNote = mission.situationNote ?? ""
        let initialHazards = mission.hazards ?? ""
        let report = SituationReport.text(for: store.state, now: Date())
        _note = State(initialValue: initialNote)
        _hazards = State(initialValue: initialHazards)
        _text = State(initialValue: report)
        _generated = State(initialValue: report)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    field("Lage in eigenen Worten", text: $note, prompt: "z. B. Pkw gegen Bus, 2 Personen eingeklemmt")
                    field("Gefahren", text: $hazards, prompt: "z. B. auslaufender Kraftstoff, Gegenverkehr")
                    HStack {
                        Text("Meldung").font(.headline)
                        Spacer()
                        if text != generated {
                            Button("Neu aus den Daten") { regenerate(force: true) }
                                .font(.subheadline)
                        }
                    }
                    TextEditor(text: $text)
                        .font(.title3)
                        .lineSpacing(4)
                        .frame(minHeight: 320)
                        .padding(Spacing.s)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Text der Lagemeldung")
                    ShareLink(item: text) {
                        Label("Teilen oder kopieren", systemImage: "square.and.arrow.up")
                            .frame(minHeight: TouchTarget.minimum)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .background(Surface.canvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Lagemeldung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ins Tagebuch", action: save).fontWeight(.bold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: note) { regenerate(force: false) }
            .onChange(of: hazards) { regenerate(force: false) }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.headline)
            HStack(alignment: .top, spacing: Spacing.s) {
                TextField(prompt, text: text, axis: .vertical)
                    .lineLimit(1...4)
                    .inputBox()
                DictationButton(text: text)
            }
        }
    }

    /// Neu erzeugen; von Hand geänderten Text nur auf Wunsch überschreiben.
    private func regenerate(force: Bool) {
        guard force || text == generated else { return }
        var state = store.state
        state.mission.situationNote = note
        state.mission.hazards = hazards
        let report = SituationReport.text(for: state, now: Date())
        generated = report
        text = report
    }

    private func save() {
        do {
            try store.perform(AddSituationReport(text: text, situationNote: note, hazards: hazards))
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Nachforderung (Schritt 68)

/// Karte „Nachforderung“ auf der Lage.
struct DemandCard: View {
    let store: MissionStore
    @State private var confirms = false
    @State private var errorMessage: String?

    var body: some View {
        let demand = ResourceDemand.calculate(store.state)
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nachforderung").font(.title2.weight(.bold))
                Spacer()
                Text(demand.patientTotal == 1 ? "1 Patient ohne Abtransport" : "\(demand.patientTotal) Patienten ohne Abtransport")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                GridRow {
                    Text("")
                    Text("vor Ort").font(.caption).foregroundStyle(.secondary)
                    Text("eingeplant").font(.caption).foregroundStyle(.secondary)
                    Text("fehlt").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(ResourceDemand.types, id: \.self) { type in
                    let missing = demand.missing[type] ?? 0
                    GridRow {
                        Text(type.shortName).font(.headline)
                        Text("\(demand.available[type] ?? 0)").monospacedDigit()
                        Text("\(demand.used[type] ?? 0)").monospacedDigit()
                        Text("\(missing)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(missing > 0 ? Color.orange : Color.secondary)
                    }
                }
            }
            if demand.hasShortfall, !store.state.mission.isClosed {
                Button { confirms = true } label: {
                    Label("Nachfordern: \(demand.missingSummary)", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                        .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .confirmationDialog("Nachfordern: \(demand.missingSummary)?", isPresented: $confirms, titleVisibility: .visible) {
                    Button("Als Platzhalter anlegen") { request(demand) }
                } message: {
                    Text("Legt Platzhalter an und vermerkt die Nachforderung im Tagebuch. Bei der ILS anfordern, dann das Fahrzeug eintragen.")
                }
            } else if demand.patientTotal > 0 {
                Label("Einheiten reichen rechnerisch.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            if demand.hasShortfall, demand.emergencyMissing != demand.missing {
                let emergency = ResourceDemand.summary(demand.emergencyMissing)
                Label(emergency.isEmpty
                      ? "Notfalls reicht es ohne zusätzlichen Notarzt (SK 1 nur mit RTW)."
                      : "Notfalls (SK 1 nur mit RTW): \(emergency)",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("SK 1: RTW + NEF oder RTH, in großer Not RTW allein · SK 2: RTW · SK 3: KTW. Platzhalter zählen als angefordert.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func request(_ demand: ResourceDemand) {
        do {
            try store.perform(RequestPlaceholders(demand.missing))
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Checkliste (Schritt 76)

struct ChecklistSheet: View {
    let store: MissionStore
    let template: ChecklistTemplate

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        let checked = store.state.checkedItems
        NavigationStack {
            List {
                Section {
                    ForEach(template.items) { item in
                        let entry = checked[item.id]
                        Button { toggle(item, isChecked: entry != nil) } label: {
                            HStack(spacing: Spacing.m) {
                                Image(systemName: entry == nil ? "circle" : "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(entry == nil ? Color.secondary : Color.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .foregroundStyle(.primary)
                                        .strikethrough(entry != nil, color: .secondary)
                                    if let entry {
                                        Text("erledigt \(entry.occurredAt.formatted(date: .omitted, time: .shortened)) Uhr")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(minHeight: TouchTarget.comfortable)
                        }
                        .disabled(store.state.mission.isClosed)
                        .accessibilityAddTraits(entry != nil ? .isSelected : [])
                    }
                } header: {
                    Text("\(checked.keys.filter { id in template.items.contains { $0.id == id } }.count) von \(template.items.count) erledigt")
                } footer: {
                    Text("Jeder Haken steht mit Uhrzeit im Tagebuch. Die Liste lässt sich in den Einstellungen anpassen.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Checkliste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
        }
    }

    private func toggle(_ item: ChecklistItem, isChecked: Bool) {
        do {
            if isChecked {
                try store.perform(UncheckChecklistItem(item.id))
            } else {
                try store.perform(CheckChecklistItem(item))
            }
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Übergabe (Schritt 75)

struct HandoverSheet: View {
    let store: MissionStore
    let people: [PersonChoice]
    let template: ChecklistTemplate

    @Environment(\.dismiss) private var dismiss
    @State private var successor: UserID?
    @State private var freeName = ""
    @State private var report: String
    @State private var confirms = false
    @State private var errorMessage: String?

    init(store: MissionStore, people: [PersonChoice], template: ChecklistTemplate) {
        self.store = store
        self.people = people
        self.template = template
        _report = State(initialValue: HandoverReport.text(for: store.state, checklist: template, now: Date()))
    }

    private var successorName: String {
        if let successor, let person = people.first(where: { $0.id == successor }) { return person.name }
        return freeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wer übernimmt?") {
                    if !people.isEmpty {
                        Picker("Benutzer", selection: $successor) {
                            Text("Andere Person").tag(UserID?.none)
                            ForEach(people) { person in
                                Text(person.detail.isEmpty ? person.name : "\(person.name) · \(person.detail)").tag(Optional(person.id))
                            }
                        }
                    }
                    if successor == nil {
                        TextField("Name, Funkrufname", text: $freeName)
                            .frame(minHeight: TouchTarget.minimum)
                    }
                }
                Section {
                    TextEditor(text: $report)
                        .font(.body)
                        .frame(minHeight: 360)
                    ShareLink(item: report) {
                        Label("Bericht teilen oder drucken", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Übergabebericht")
                } footer: {
                    Text("Aus den Einsatzdaten erstellt; vor der Übergabe ergänzen. Er steht danach im Tagebuch.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
                Section {
                    Button { confirms = true } label: {
                        Text("Übergabe abschließen")
                            .font(.title3.weight(.heavy))
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                    }
                    .disabled(successorName.isEmpty)
                }
            }
            .navigationTitle("Übergabe an die Ablösung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .confirmationDialog("Einsatzleitung an \(successorName) übergeben?", isPresented: $confirms, titleVisibility: .visible) {
                Button("Übergeben", action: handOver)
            } message: {
                Text("\(successorName) wird als Einsatzleiter eingetragen, der Bericht kommt ins Tagebuch.")
            }
        }
    }

    private func handOver() {
        do {
            try store.perform(HandOverMission(newCommanderID: successor, newCommanderName: successorName, report: report))
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - Kliniken und Kontingente (Schritt 71)

struct HospitalQuotaSheet: View {
    let store: MissionStore
    let hospitals: [MasterHospital]

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var errorMessage: String?
    /// Klinik-Voranmeldung (Schritt 98).
    @State private var preannouncement: HospitalPreannouncement?

    var body: some View {
        let loads = HospitalDistribution.loads(store.state)
        let announcements = HospitalPreannouncement.all(mission: store.state.mission, patients: store.state.patients, units: store.state.units)
        NavigationStack {
            List {
                if loads.isEmpty {
                    Text("Noch keine Klinik mit Kontingent oder zugewiesenen Patienten.")
                        .foregroundStyle(.secondary)
                }
                ForEach(loads) { load in
                    Section {
                        ForEach([Sichtungskategorie.sk1, .sk2, .sk3], id: \.self) { triage in
                            quotaRow(load, triage: triage)
                        }
                        if let announcement = announcements.first(where: { $0.id == HospitalQuota.key(load.name) }) {
                            Button {
                                preannouncement = announcement
                            } label: {
                                Label("Voranmeldung (\(announcement.patientCount) Patienten)", systemImage: "paperplane")
                                    .frame(minHeight: TouchTarget.minimum)
                            }
                        }
                        if let quota = load.quota, load.total == 0 {
                            Button("Aus der Liste entfernen", role: .destructive) {
                                do { try store.perform(RemoveHospitalQuota(quotaID: quota.id)) } catch { errorMessage = ErrorText.message(for: error) }
                            }
                        }
                    } header: {
                        HStack {
                            Text(load.name)
                            if !load.overloadedTriages.isEmpty {
                                Label("über Kontingent", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .textCase(nil)
                            }
                        }
                    }
                }
                Section("Klinik hinzufügen") {
                    let listed = Set(loads.map { HospitalQuota.key($0.name) })
                    let options = hospitals.filter { !listed.contains(HospitalQuota.key($0.name)) }
                    if !options.isEmpty {
                        Menu {
                            ForEach(options) { hospital in
                                Button(hospital.name) { add(hospital.snapshot) }
                            }
                        } label: {
                            Label("Aus Stammdaten wählen", systemImage: "building.2")
                                .frame(minHeight: TouchTarget.minimum)
                        }
                    }
                    HStack {
                        TextField("Klinikname", text: $newName)
                        Button("Hinzufügen") {
                            add(HospitalSnapshot(name: newName))
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(minHeight: TouchTarget.minimum)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Kliniken und Kontingente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
        .sheet(item: $preannouncement) { announcement in
            ShareTextSheet(
                title: "Voranmeldung",
                text: announcement.text,
                email: announcement.email ?? hospitals.first { HospitalQuota.key($0.name) == announcement.id }?.email,
                subject: "Voranmeldung \(announcement.hospitalName)",
                footnote: "Ohne Patientennamen. Per Mail nur, wenn für die Klinik eine Adresse hinterlegt ist."
            )
            .largeSheet()
        }
        }
    }

    private func quotaRow(_ load: HospitalLoad, triage: Sichtungskategorie) -> some View {
        let count = load.counts[triage] ?? 0
        let limit = load.quota?.limit(for: triage)
        return HStack(spacing: Spacing.m) {
            Text(triage.shortName)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.onTriage(triage))
                .frame(minWidth: 52, minHeight: 32)
                .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(limit.map { "\(count) von \($0)" } ?? "\(count) Patienten")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle((limit.map { count > $0 } ?? false) ? Color.orange : Color.primary)
                if limit != nil {
                    // Zurücksetzen bewusst unter der Zahl: Plus und Minus bleiben an ihrem Platz.
                    Button("Kontingent entfernen") { setLimit(load, triage, nil) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                } else {
                    Text("ohne Kontingent").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { setLimit(load, triage, limit.map { max(0, $0 - 1) } ?? count) } label: {
                Image(systemName: "minus.circle.fill").font(.title)
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
            }
            .buttonStyle(.borderless)
            .disabled(limit == 0)
            .accessibilityLabel("\(triage.shortName) Kontingent verringern")
            Text(limit.map(String.init) ?? "–")
                .font(.title3.weight(.heavy).monospacedDigit())
                .frame(minWidth: 36)
            Button { setLimit(load, triage, (limit ?? count) + 1) } label: {
                Image(systemName: "plus.circle.fill").font(.title)
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(triage.shortName) Kontingent erhöhen")
        }
        .frame(minHeight: TouchTarget.comfortable)
        .disabled(store.state.mission.isClosed)
    }

    private func setLimit(_ load: HospitalLoad, _ triage: Sichtungskategorie, _ value: Int?) {
        var quota = load.quota ?? HospitalQuota(masterHospitalID: load.hospital?.masterHospitalID, hospitalName: load.name)
        quota.setLimit(value, for: triage)
        perform(quota)
    }

    private func add(_ hospital: HospitalSnapshot) {
        guard !hospital.name.isEmpty else { return }
        // Erst ohne Grenzen in die Liste; Plätze je SK dann mit + eintragen.
        perform(HospitalQuota(masterHospitalID: hospital.masterHospitalID, hospitalName: hospital.name))
    }

    private func perform(_ quota: HospitalQuota) {
        do {
            try store.perform(SetHospitalQuota(quota))
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
