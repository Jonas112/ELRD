import SwiftUI
import ELRDDomain
import ELRDReports
import ELRDStore
import ELRDPersistence

/// Berichts-Editor (Schritt 44): links Vorlage, Kapitel mit Optionen und Gestaltung,
/// rechts die Vorschau, die sich nach jeder Änderung neu aufbaut (im Hintergrund).
/// Schmal: Umschalter „Inhalt | Vorschau“. Unten Teilen, Drucken, Mail an ILS (Schritt 46).
struct ReportEditorView: View {
    enum Pane: Hashable { case content, preview }

    let store: MissionStore
    let people: [PersonChoice]
    let onClose: () -> Void

    @Environment(\.attachmentStore) private var attachments
    @Environment(ReportLibraryStore.self) private var library: ReportLibraryStore?
    @Environment(AppSettingsStore.self) private var settings: AppSettingsStore?

    @State private var template = ReportTemplateLibrary.full
    @State private var isPrepared = false
    @State private var pdf: Data?
    @State private var isRendering = false
    @State private var pane: Pane = .content
    @State private var expanded: ReportChapter.Kind?
    @State private var showsSaveAs = false
    @State private var newName = ""
    @State private var showsMail = false
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    private var templates: [ReportTemplate] { library?.library.all ?? ReportTemplateLibrary.standardTemplates }
    private var isStandard: Bool { ReportTemplateLibrary.isStandard(template.id) }
    private var savedVersion: ReportTemplate? { library?.library.template(id: template.id) }
    private var isModified: Bool { savedVersion.map { $0 != template } ?? true }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width >= 900 {
                    HStack(spacing: 0) {
                        settingsColumn.frame(width: 400)
                        Divider()
                        previewColumn
                    }
                } else {
                    VStack(spacing: 0) {
                        SegmentedChoice(options: [(Pane.content, "Inhalt"), (.preview, "Vorschau")], selection: $pane)
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, Spacing.s)
                        if pane == .content { settingsColumn } else { previewColumn }
                    }
                }
            }
            .background(Surface.canvas)
            .navigationTitle("Bericht")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: onClose) }
                ToolbarItemGroup(placement: .primaryAction) { outputButtons }
            }
        }
        .task(id: template) { await render() }
        .onAppear(perform: prepare)
        .alert("Als Vorlage speichern", isPresented: $showsSaveAs) {
            TextField("Name der Vorlage", text: $newName)
            Button("Speichern") { saveAs() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Vorlage steht danach bei jedem Einsatz zur Auswahl.")
        }
        .alert("Hinweis", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showsMail) {
            if let pdf {
                MailComposer(
                    recipient: settings?.settings.ilsEmail.trimmingCharacters(in: .whitespaces) ?? "",
                    subject: "\(template.name) Einsatz \(store.state.mission.displayNumber()) – \(store.state.mission.title)",
                    body: "Im Anhang der \(template.name) zum Einsatz \(store.state.mission.displayNumber()).\n\n\(store.sessionDisplayName)",
                    attachment: pdf,
                    fileName: fileName,
                    onFinish: { showsMail = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Einstellungen

    private var settingsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                templateSection
                chapterSection
                designSection
            }
            .padding(Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Vorlage").font(.headline).foregroundStyle(.secondary)
            Menu {
                ForEach(templates) { candidate in
                    Button {
                        template = withSettings(candidate)
                    } label: {
                        if candidate.id == template.id { Label(candidate.name, systemImage: "checkmark") } else { Text(candidate.name) }
                    }
                }
            } label: {
                HStack {
                    Text(template.name).font(.title3.weight(.bold)).foregroundStyle(.primary)
                    if isModified { Text("geändert").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: TouchTarget.comfortable)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: Spacing.s) {
                if !isStandard {
                    Button("Speichern") { save(template) }
                        .buttonStyle(.bordered)
                        .disabled(!isModified)
                }
                Button("Als neue Vorlage …") {
                    newName = isStandard ? "\(template.name) (eigene)" : "\(template.name) Kopie"
                    showsSaveAs = true
                }
                .buttonStyle(.bordered)
                if !isStandard {
                    Button("Löschen", role: .destructive) { deleteTemplate() }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
    }

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Kapitel").font(.headline).foregroundStyle(.secondary)
            ForEach(template.chapters.indices, id: \.self) { index in
                chapterRow(index)
            }
        }
    }

    private func chapterRow(_ index: Int) -> some View {
        let chapter = template.chapters[index]
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Toggle(isOn: $template.chapters[index].isEnabled) {
                    Text(chapter.kind.displayName).font(.headline)
                }
                .toggleStyle(.switch)
                .fixedSize()
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("\(chapter.kind.displayName) nach oben")
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == template.chapters.count - 1)
                    .accessibilityLabel("\(chapter.kind.displayName) nach unten")
                Button {
                    withAnimation { expanded = expanded == chapter.kind ? nil : chapter.kind }
                } label: {
                    Image(systemName: expanded == chapter.kind ? "chevron.up" : "slider.horizontal.3")
                }
                .accessibilityLabel("Optionen \(chapter.kind.displayName)")
            }
            .buttonStyle(.bordered)
            if expanded == chapter.kind {
                ReportChapterOptionsView(kind: chapter.kind, options: $template.chapters[index].options)
                    .padding(.leading, Spacing.s)
            }
        }
        .padding(Spacing.m)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(chapter.isEnabled ? 1 : 0.6)
    }

    private var designSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Gestaltung").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: Spacing.s) {
                ForEach(ReportDesignPalette.accents.indices, id: \.self) { index in
                    let entry = ReportDesignPalette.accents[index]
                    Button { template.theme.accent = entry.color } label: {
                        Circle().fill(Color(entry.color)).frame(width: 36, height: 36)
                            .overlay {
                                if template.theme.accent == entry.color {
                                    Image(systemName: "checkmark").font(.headline.weight(.heavy)).foregroundStyle(.white)
                                }
                            }
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Akzentfarbe \(entry.name)")
                }
            }
            SegmentedChoice(options: ReportTheme.Orientation.allCases.map { ($0, $0.displayName) }, selection: $template.theme.orientation)
            Stepper(value: $template.theme.baseFontSize, in: 8...14, step: 1) {
                Text("Schriftgröße \(Int(template.theme.baseFontSize)) pt")
            }
            .frame(minHeight: TouchTarget.minimum)
            Toggle("SK-Farben (aus für Schwarzweißdruck)", isOn: $template.theme.showsTriageColors)
            Toggle("Tabellenzeilen abwechselnd hinterlegen", isOn: $template.theme.zebraRows)
            TextField("Zeile im Kopf, z. B. Organisation", text: $template.theme.bannerText)
                .inputBox()
        }
    }

    // MARK: Vorschau

    private var previewColumn: some View {
        ZStack {
            if let pdf {
                PDFPreview(data: pdf)
            } else {
                ProgressView("Bericht wird erstellt …")
            }
            if isRendering, pdf != nil {
                ProgressView()
                    .padding(Spacing.m)
                    .background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(Spacing.l)
            }
        }
    }

    // MARK: Ausgabe (Schritt 46)

    @ViewBuilder
    private var outputButtons: some View {
        if let shareURL {
            ShareLink(item: shareURL) { Label("Teilen", systemImage: "square.and.arrow.up") }
        }
        Button {
            if let pdf { ReportPrinting.print(pdf, jobName: fileName) }
        } label: {
            Label("Drucken", systemImage: "printer")
        }
        .disabled(pdf == nil)
        Button { sendMail() } label: {
            Label("An ILS", systemImage: "envelope")
        }
        .disabled(pdf == nil)
    }

    private var fileName: String {
        ReportFileName.make(template: template.name, mission: store.state.mission, date: Date())
    }

    private func sendMail() {
        guard MailComposer.canSend else {
            errorMessage = "Auf diesem iPad ist kein Mailkonto eingerichtet. Über „Teilen“ lässt sich der Bericht trotzdem versenden."
            return
        }
        // Ohne hinterlegte ILS-Adresse öffnet die Mail mit leerem Empfänger
        // (Adresse unter Einstellungen → Allgemein eintragen).
        showsMail = true
    }

    // MARK: Ablauf

    private func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        let preferred = library?.library.template(id: settings?.settings.defaultReportTemplateID) ?? ReportTemplateLibrary.full
        template = withSettings(preferred)
    }

    /// Kopfzeile aus den Einstellungen übernehmen (Organisation, Banner).
    private func withSettings(_ base: ReportTemplate) -> ReportTemplate {
        var adjusted = base
        if let settings { adjusted.theme = settings.reportTheme(base: base.theme) }
        return adjusted
    }

    /// Kurz warten (Tippen am Stepper), dann im Hintergrund rendern.
    private func render() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        isRendering = true
        let input = ReportInputFactory.make(store: store, people: people, attachments: attachments)
        let current = template
        let data = await Task.detached(priority: .userInitiated) {
            ReportBuilder.pdf(for: current, input: input)
        }.value
        guard !Task.isCancelled else { return }
        pdf = data
        isRendering = false
        shareURL = try? ReportFileName.write(data, named: fileName)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard template.chapters.indices.contains(target) else { return }
        withAnimation { template.chapters.swapAt(index, target) }
    }

    private func save(_ candidate: ReportTemplate) {
        do {
            if let stored = try library?.save(candidate) { template = stored }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func saveAs() {
        var copy = template
        copy.id = UUID()
        copy.name = newName
        save(copy)
    }

    private func deleteTemplate() {
        do {
            try library?.delete(template.id)
            template = withSettings(ReportTemplateLibrary.full)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Optionen eines Kapitels.
struct ReportChapterOptionsView: View {
    let kind: ReportChapter.Kind
    @Binding var options: ReportChapterOptions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            switch kind {
            case .missionInfo:
                Toggle("Lage in Zahlen", isOn: $options.showsSummary)
                Toggle("Lagekarte aus dem Tagebuch", isOn: $options.showsMapImage)
            case .organisation:
                Toggle("Platzhalter aufführen", isOn: $options.includesPlaceholders)
                Toggle("Zugeordnete Patienten nennen", isOn: $options.showsPatientAssignment)
            case .patients:
                Toggle("Einzelbogen je Patient", isOn: $options.usesPatientSheets)
                Toggle("Namen zeigen", isOn: $options.showsPatientNames)
                Text("Nur Sichtungskategorien (keine = alle)").font(.subheadline).foregroundStyle(.secondary)
                FlowLayout(spacing: Spacing.s) {
                    ForEach([Sichtungskategorie.sk1, .sk2, .sk3, .ungesichtet, .unverletzt, .verstorben], id: \.self) { triage in
                        ChoiceChip(triage.shortName, isSelected: options.triageFilter.contains(triage), minHeight: TouchTarget.minimum) {
                            if options.triageFilter.contains(triage) { options.triageFilter.remove(triage) } else { options.triageFilter.insert(triage) }
                        }
                    }
                }
            case .journal:
                Picker("Bilder", selection: $options.journalImageHeight) {
                    Text("Keine").tag(0.0)
                    Text("Klein").tag(140.0)
                    Text("Mittel").tag(220.0)
                    Text("Groß").tag(360.0)
                }
                .pickerStyle(.segmented)
            case .log:
                Text("Nur Bereiche (keine = alle)").font(.subheadline).foregroundStyle(.secondary)
                FlowLayout(spacing: Spacing.s) {
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        ChoiceChip(category.displayName, isSelected: options.logCategories.contains(category), minHeight: TouchTarget.minimum) {
                            if options.logCategories.contains(category) { options.logCategories.remove(category) } else { options.logCategories.insert(category) }
                        }
                    }
                }
            }
        }
        .font(.body)
    }
}

/// Akzentfarben für Berichte.
enum ReportDesignPalette {
    static let accents: [(name: String, color: RGBColor)] = [
        ("Blau", RGBColor(hex: 0x1F5FAD)),
        ("Rot", RGBColor(hex: 0xC62828)),
        ("Grün", RGBColor(hex: 0x2E7D32)),
        ("Petrol", RGBColor(hex: 0x00695C)),
        ("Grau", RGBColor(hex: 0x455A64)),
        ("Schwarz", RGBColor(hex: 0x212121)),
    ]
}
