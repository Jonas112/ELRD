import SwiftUI
import UIKit
import PhotosUI
import ELRDDomain
import ELRDReports
import ELRDStammdaten
import ELRDEntitlements

/// Einstellungen (Schritte 47–51): Allgemein, Fahrzeugbilder, Stammdaten, IVENA,
/// Abo, Vereinbarungen. Stammdaten ändern nur Administratoren.
struct SettingsView: View {
    enum Page: Hashable { case general, missionAids, vehicleImages, masterData, ivena, subscription, agreements }

    let masterData: MasterDataEditor?
    let isAdmin: Bool
    var initialPage: Page?
    let onClose: () -> Void

    @State private var path: [Page] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    row(.general, "Allgemein", "gearshape", "Organisation, Banner, ILS-Mail, Standardbericht")
                    row(.missionAids, "Erinnerungen, Einsatzarten, Checklisten", "checklist", "Lagemeldung im Takt, Wartezeiten, Checkliste je Einsatzart")
                    row(.vehicleImages, "Fahrzeugbilder", "car.2", "Eigene Bilder für RTW, KTW, NEF, RTH")
                }
                Section {
                    row(.masterData, "Stammdaten", "list.bullet.rectangle", "Fahrzeuge, Kliniken, Abschnitte, Regionen")
                    row(.ivena, "IVENA", "cross.case", "Katalog, Anzeige beim Patienten")
                }
                Section {
                    row(.subscription, "Abo", "creditcard", "Freischaltung und Kauf")
                    row(.agreements, "Vereinbarungen", "doc.text", "Nutzungsbedingungen, Datenschutz")
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: onClose).fontWeight(.bold) }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .general: GeneralSettingsView()
                case .missionAids: MissionAidsSettingsView()
                case .vehicleImages: VehicleImagesView()
                case .masterData: MasterDataSettingsView(masterData: masterData, isAdmin: isAdmin)
                case .ivena: IVENASettingsView(masterData: masterData, isAdmin: isAdmin)
                case .subscription: SubscriptionView()
                case .agreements: AgreementsView()
                }
            }
        }
        .onAppear {
            if let initialPage, path.isEmpty { path = [initialPage] }
        }
    }

    private func row(_ page: Page, _ title: String, _ symbol: String, _ detail: String) -> some View {
        NavigationLink(value: page) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
            .frame(minHeight: TouchTarget.comfortable)
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }
}

/// Fehleranzeige für Einstellungsseiten.
private struct SettingsErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Nicht gespeichert", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func settingsError(_ message: Binding<String?>) -> some View { modifier(SettingsErrorAlert(message: message)) }
}

// MARK: - Allgemein (Schritt 47)

struct GeneralSettingsView: View {
    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @Environment(ReportLibraryStore.self) private var library: ReportLibraryStore?

    @State private var organisation = ""
    @State private var ilsEmail = ""
    @State private var bannerItem: PhotosPickerItem?
    @State private var errorMessage: String?

    var body: some View {
        let settings = store?.settings ?? AppSettings()
        Form {
            Section {
                TextField("z. B. BRK Kreisverband Schweinfurt", text: $organisation)
                    .onSubmit(commitText)
            } header: {
                Text("Organisation")
            } footer: {
                Text("Erscheint im Kopf der Berichte.")
            }

            Section {
                if let data = settings.bannerImage, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 90)
                    Button("Banner entfernen", role: .destructive) { save { $0.bannerImage = nil } }
                }
                PhotosPicker(selection: $bannerItem, matching: .images) {
                    Label(settings.bannerImage == nil ? "Banner oder Logo wählen" : "Anderes Bild wählen", systemImage: "photo")
                }
            } header: {
                Text("Banner / Logo")
            } footer: {
                Text("Oben in der Einsatzliste und oben links im Bericht. Am besten ein Logo mit hellem oder durchsichtigem Hintergrund.")
            }

            Section {
                TextField("ils@beispiel.de", text: $ilsEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(commitText)
                if !ilsEmail.isEmpty, !draftEmailIsValid {
                    Label("Diese Adresse sieht unvollständig aus.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("E-Mail der Leitstelle")
            } footer: {
                Text("Empfänger für „Bericht an ILS“.")
            }

            MapCacheSection()

            Section("Standardbericht") {
                Picker("Vorlage", selection: Binding(
                    get: { settings.defaultReportTemplateID ?? ReportTemplateLibrary.fullID },
                    set: { id in save { $0.defaultReportTemplateID = id } }
                )) {
                    ForEach(library?.library.all ?? ReportTemplateLibrary.standardTemplates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
            }
        }
        .navigationTitle("Allgemein")
        .onAppear {
            organisation = settings.organisationName
            ilsEmail = settings.ilsEmail
        }
        .onDisappear(perform: commitText)
        .onChange(of: bannerItem) { _, item in
            guard let item else { return }
            Task { await loadBanner(item) }
        }
        .settingsError($errorMessage)
    }

    private var draftEmailIsValid: Bool {
        var probe = AppSettings()
        probe.ilsEmail = ilsEmail
        return probe.hasValidILSEmail
    }

    private func commitText() {
        let name = organisation.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = ilsEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        save { settings in
            settings.organisationName = name
            settings.ilsEmail = mail
        }
    }

    private func loadBanner(_ item: PhotosPickerItem) async {
        defer { bannerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "Das Bild ließ sich nicht laden."
            return
        }
        // Verkleinert und als PNG (Transparenz bleibt erhalten).
        let png = ImageResizing.png(image, maxPixel: 800)
        save { $0.bannerImage = png }
    }

    private func save(_ change: (inout AppSettings) -> Void) {
        do { try store?.update(change) } catch { errorMessage = ErrorText.message(for: error) }
    }
}

/// Bilder verkleinern (Banner, Fahrzeugbilder).
enum ImageResizing {
    static func png(_ image: UIImage, maxPixel: CGFloat) -> Data? {
        let scale = min(1, maxPixel / max(image.size.width * image.scale, image.size.height * image.scale, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }
}

// MARK: - Fahrzeugbilder (Schritt 47)

struct VehicleImagesView: View {
    static let types: [UnitType] = [.rtw, .ktw, .nef, .rth]

    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var picking: UnitType?
    @State private var item: PhotosPickerItem?
    @State private var errorMessage: String?

    var body: some View {
        let settings = store?.settings ?? AppSettings()
        List {
            Section {
                ForEach(Self.types) { type in
                    HStack(spacing: Spacing.m) {
                        Group {
                            if let data = settings.image(for: type), let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit()
                            } else {
                                Text(type.shortName).font(.headline.weight(.heavy))
                            }
                        }
                        .frame(width: 88, height: 56)
                        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(type.displayName).font(.headline)
                        Spacer()
                        if settings.image(for: type) != nil {
                            Button("Entfernen", role: .destructive) { save { $0.unitTypeImages[type.rawValue] = nil } }
                                .buttonStyle(.bordered)
                        }
                        PhotosPicker(selection: Binding(get: { item }, set: { newItem in picking = type; item = newItem }), matching: .images) {
                            Text("Bild wählen")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(minHeight: 64)
                }
            } footer: {
                Text("Erscheinen in der Einheitenübersicht neben dem Typ-Kennzeichen (wie im bisherigen ELRDRG).")
            }
        }
        .navigationTitle("Fahrzeugbilder")
        .onChange(of: item) { _, newItem in
            guard let newItem, let type = picking else { return }
            Task { await load(newItem, for: type) }
        }
        .settingsError($errorMessage)
    }

    private func load(_ selected: PhotosPickerItem, for type: UnitType) async {
        defer {
            item = nil
            picking = nil
        }
        guard let data = try? await selected.loadTransferable(type: Data.self), let image = UIImage(data: data),
              let png = ImageResizing.png(image, maxPixel: 320) else {
            errorMessage = "Das Bild ließ sich nicht laden."
            return
        }
        save { $0.unitTypeImages[type.rawValue] = png }
    }

    private func save(_ change: (inout AppSettings) -> Void) {
        do { try store?.update(change) } catch { errorMessage = ErrorText.message(for: error) }
    }
}

// MARK: - IVENA (Schritt 49)

struct IVENASettingsView: View {
    let masterData: MasterDataEditor?
    let isAdmin: Bool

    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var search = ""
    @State private var catalog: RMICatalog?
    @State private var errorMessage: String?

    private var selectedID: String { masterData?.ivenaCatalogID ?? BundledMasterData.ivenaCatalogs.first?.id ?? "" }

    var body: some View {
        let settings = store?.settings ?? AppSettings()
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.showsIVENA },
                    set: { on in save { $0.showsIVENA = on } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IVENA beim Patienten").font(.headline)
                        Text("RMI, Dringlichkeit, PZC und ABCD-Status. Aus, wenn die Leitstelle kein IVENA nutzt.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            }
            Section("RMI-Katalog") {
                ForEach(BundledMasterData.ivenaCatalogs, id: \.id) { entry in
                    Button {
                        do { try masterData?.setIVENACatalog(entry.id) } catch { errorMessage = ErrorText.message(for: error) }
                    } label: {
                        HStack {
                            Text(entry.name).foregroundStyle(.primary)
                            Spacer()
                            if entry.id == selectedID { Image(systemName: "checkmark").foregroundStyle(ActionFill.primary) }
                        }
                        .frame(minHeight: TouchTarget.minimum)
                    }
                    .disabled(!isAdmin)
                }
            }
            if let catalog {
                Section("\(catalog.entries.count) Rückmeldeindikatoren") {
                    TextField("Suchen (Nummer oder Text)", text: $search)
                    ForEach(filtered(catalog)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.code) – \(entry.title)").font(.body)
                            Text(entry.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("IVENA")
        .task(id: selectedID) {
            catalog = try? BundledMasterData.ivenaCatalog(id: selectedID)
        }
        .settingsError($errorMessage)
    }

    private func filtered(_ catalog: RMICatalog) -> [RMI] {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return Array(catalog.entries.prefix(200)) }
        return catalog.entries.filter { entry in
            words.allSatisfy { "\(entry.code) \(entry.title) \(entry.category)".range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private func save(_ change: (inout AppSettings) -> Void) {
        do { try store?.update(change) } catch { errorMessage = ErrorText.message(for: error) }
    }
}

/// Speicher der Kartenkacheln (Schritt 59): Größe und Leeren.
private struct MapCacheSection: View {
    @State private var bytes: Int?

    var body: some View {
        Section {
            HStack {
                Text("Gespeicherte Kartenkacheln")
                Spacer()
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                    .foregroundStyle(.secondary)
            }
            Button("Kartenspeicher leeren", role: .destructive) {
                TileDiskCache.shared.clear()
                bytes = 0
            }
            .disabled(bytes == 0)
        } header: {
            Text("Offline-Karte")
        } footer: {
            Text("OpenStreetMap und Topografisch bleiben dort verfügbar, wo die Karte schon einmal angesehen wurde – auch ohne Netz. Höchstens 300 MB, älteste Kacheln werden zuerst entfernt.")
        }
        .task {
            let cache = TileDiskCache.shared
            bytes = await Task.detached { () -> Int in
                cache.prune()
                return cache.sizeInBytes()
            }.value
        }
    }
}

/// Erinnerungen (Schritt 69), Einsatzarten und Checklisten (Schritte 76, 78).
struct MissionAidsSettingsView: View {
    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var newType = ""
    @State private var errorMessage: String?

    var body: some View {
        let settings = store?.settings ?? AppSettings()
        let lists = settings.effectiveChecklists
        Form {
            Section {
                minutesPicker("Lagemeldung an ILS alle", value: settings.reminders.situationReportMinutes) { value in
                    save { $0.reminders.situationReportMinutes = value }
                }
                minutesPicker("Patient wartet zu lange ab", value: settings.reminders.transportWaitMinutes) { value in
                    save { $0.reminders.transportWaitMinutes = value }
                }
                minutesPicker("Platzhalter ohne Fahrzeug ab", value: settings.reminders.placeholderMinutes) { value in
                    save { $0.reminders.placeholderMinutes = value }
                }
            } header: {
                Text("Erinnerungen")
            } footer: {
                Text("Erscheinen unter „Offene Punkte“ in der Lage. „Aus“ schaltet die Erinnerung ab.")
            }

            Section {
                ForEach(settings.effectiveMissionTypes) { entry in
                    Picker(selection: Binding(
                        get: { entry.checklistID },
                        set: { id in updateTypes { types in
                            if let index = types.firstIndex(where: { $0.id == entry.id }) { types[index].checklistID = id }
                        } }
                    )) {
                        Text("Standard (wie ohne Einsatzart)").tag(String?.none)
                        ForEach(lists) { list in Text(list.name).tag(Optional(list.id)) }
                    } label: {
                        Text(entry.type.displayName).font(.headline)
                    }
                    .frame(minHeight: TouchTarget.minimum)
                }
                .onDelete { offsets in updateTypes { $0.remove(atOffsets: offsets) } }
                .onMove { from, to in updateTypes { $0.move(fromOffsets: from, toOffset: to) } }
                HStack {
                    TextField("Neue Einsatzart, z. B. Großveranstaltung", text: $newType)
                        .onSubmit(addType)
                    Button("Hinzufügen", action: addType)
                        .disabled(MissionType(customName: newType) == nil)
                }
                .frame(minHeight: TouchTarget.minimum)
                let missing = MissionType.defaultOrder.filter { type in !settings.effectiveMissionTypes.contains { $0.type == type } }
                if !missing.isEmpty {
                    Menu {
                        ForEach(missing, id: \.self) { type in
                            Button(type.displayName) { updateTypes { $0.append(MissionTypeSetting(type: type)) } }
                        }
                    } label: {
                        Label("Mitgelieferte Einsatzart wieder aufnehmen", systemImage: "plus.circle")
                    }
                }
            } header: {
                HStack {
                    Text("Einsatzarten und ihre Checkliste")
                    Spacer()
                    EditButton().textCase(nil)
                }
            } footer: {
                Text("Diese Arten stehen bei „Neuer Einsatz“ zur Auswahl. Wischen entfernt eine Art; bestehende Einsätze behalten ihre Art.")
            }

            Section {
                Picker("Checkliste", selection: Binding(
                    get: { settings.namedChecklist(for: nil).id },
                    set: { id in save { $0.defaultChecklistID = id } }
                )) {
                    ForEach(lists) { list in Text(list.name).tag(list.id) }
                }
                .frame(minHeight: TouchTarget.minimum)
            } header: {
                Text("Ohne Einsatzart")
            } footer: {
                Text("Gilt für Einsätze ohne Einsatzart und für Arten mit „Standard“.")
            }

            Section {
                ForEach(lists) { list in
                    NavigationLink {
                        ChecklistEditorView(checklistID: list.id)
                    } label: {
                        LabeledContent(list.name, value: "\(list.items.count) Punkte")
                    }
                    .frame(minHeight: TouchTarget.minimum)
                }
                .onDelete { offsets in
                    guard lists.count - offsets.count >= 1 else {
                        errorMessage = "Mindestens eine Checkliste muss bleiben."
                        return
                    }
                    let removed = Set(offsets.map { lists[$0].id })
                    save { settings in
                        var all = settings.effectiveChecklists
                        all.removeAll { removed.contains($0.id) }
                        settings.checklists = all
                        settings.missionTypes = settings.effectiveMissionTypes.map { entry in
                            var entry = entry
                            if let id = entry.checklistID, removed.contains(id) { entry.checklistID = nil }
                            return entry
                        }
                        if let id = settings.defaultChecklistID, removed.contains(id) { settings.defaultChecklistID = nil }
                    }
                }
                Button {
                    save { settings in
                        var all = settings.effectiveChecklists
                        all.append(NamedChecklist(name: "Neue Checkliste \(all.count + 1)", items: ChecklistTemplate.standard.items.map { ChecklistItem(title: $0.title) }))
                        settings.checklists = all
                    }
                } label: {
                    Label("Neue Checkliste", systemImage: "plus")
                }
            } header: {
                Text("Checklisten")
            } footer: {
                Text("Eine neue Liste startet mit den Standardpunkten. Antippen zum Umbenennen und Bearbeiten.")
            }
        }
        .navigationTitle("Erinnerungen und Checklisten")
        .settingsError($errorMessage)
    }

    private func minutesPicker(_ title: String, value: Int, onChange: @escaping (Int) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: onChange)) {
            ForEach(ReminderSettings.choices, id: \.self) { minutes in
                Text(minutes == 0 ? "Aus" : "\(minutes) min").tag(minutes)
            }
        }
        .frame(minHeight: TouchTarget.minimum)
    }

    private func addType() {
        guard let type = MissionType(customName: newType) else { return }
        let existing = store?.settings.effectiveMissionTypes ?? []
        guard !existing.contains(where: { $0.type == type }) else {
            errorMessage = "„\(type.displayName)“ gibt es schon."
            return
        }
        updateTypes { $0.append(MissionTypeSetting(type: type)) }
        newType = ""
    }

    private func updateTypes(_ change: (inout [MissionTypeSetting]) -> Void) {
        save { settings in
            var types = settings.effectiveMissionTypes
            change(&types)
            settings.missionTypes = types
        }
    }

    private func save(_ change: (inout AppSettings) -> Void) {
        do {
            try store?.update(change)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Name und Punkte einer Checkliste (eine Zeile je Punkt).
struct ChecklistEditorView: View {
    let checklistID: String

    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var name = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var errorMessage: String?

    private var current: NamedChecklist? {
        store?.settings.effectiveChecklists.first { $0.id == checklistID }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .frame(minHeight: TouchTarget.minimum)
            }
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 320)
            } header: {
                Text("Punkte")
            } footer: {
                Text("Ein Punkt je Zeile. Abgehakte Punkte bleiben abgehakt, solange ihr Text gleich bleibt.")
            }
        }
        .navigationTitle(name.isEmpty ? "Checkliste" : name)
        .onAppear {
            guard !loaded, let current else { return }
            name = current.name
            text = current.template.lines
            loaded = true
        }
        .onDisappear(perform: commit)
        .settingsError($errorMessage)
    }

    private func commit() {
        guard let current else { return }
        let items = current.template.updated(fromLines: text).items
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !items.isEmpty else {
            errorMessage = "Die Checkliste braucht mindestens einen Punkt."
            return
        }
        do {
            try store?.update { settings in
                var all = settings.effectiveChecklists
                guard let index = all.firstIndex(where: { $0.id == checklistID }) else { return }
                all[index] = NamedChecklist(id: checklistID, name: trimmed.isEmpty ? current.name : trimmed, items: items)
                settings.checklists = all
            }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

