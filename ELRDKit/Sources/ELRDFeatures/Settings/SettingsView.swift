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
    enum Page: Hashable { case general, missionAids, leadershipPeople, vehicleImages, masterData, ivena, subscription, agreements }

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
                    row(.leadershipPeople, "Führungspersonal", "person.3.sequence", "ELRD, LNA, OrgL, Abschnittsleiter zur Auswahl")
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
                case .leadershipPeople: LeadershipPeopleSettingsView()
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

            Section {
                Toggle(isOn: Binding(get: { settings.gloveMode }, set: { on in save { $0.gloveMode = on } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Handschuhmodus", systemImage: "hand.raised.fill").font(.headline)
                        Text("Größere Knöpfe, Tippflächen und Schrift – für Handschuhe und Regen.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
                Toggle(isOn: Binding(get: { settings.nightMode }, set: { on in save { $0.nightMode = on } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Nachtmodus", systemImage: "moon.stars.fill").font(.headline)
                        Text("Dunkle, gedimmte Darstellung, die nachts nicht blendet. Displayhelligkeit zusätzlich im Kontrollzentrum senken.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            } header: {
                Text("Darstellung im Einsatz")
            } footer: {
                Text("Gilt für dieses Gerät.")
            }

            Section {
                Toggle(isOn: Binding(get: { settings.requiresJoinApproval }, set: { on in save { $0.requiresJoinApproval = on } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Beitritt genehmigen", systemImage: "person.badge.shield.checkmark")
                            .font(.headline)
                        Text("Wer einem von dir geteilten Einsatz beitreten will, schickt eine Anfrage; du lässt zu oder lehnst ab. Vorher kommen keine Einsatzdaten auf das andere Gerät.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            } header: {
                Text("Geteilte Einsätze (iCloud)")
            } footer: {
                Text("Gilt für Einsätze, die ab jetzt geteilt werden. Bereits geteilte behalten ihre Art – zum Umstellen Teilen beenden und neu teilen.")
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

    /// Schritt 106: Vorlage einer Einsatzart bearbeiten.
    @State private var editingTemplate: String?

    var body: some View {
        let settings = store?.settings ?? AppSettings()
        let lists = settings.effectiveChecklists
        Form {
            Section {
                Picker(selection: Binding(
                    get: { settings.anonymizeAfterDays },
                    set: { value in save { $0.anonymizeAfterDays = value } }
                )) {
                    ForEach(AppSettings.anonymizeChoices, id: \.self) { days in
                        Text(days == 0 ? "Aus" : "nach \(days) Tagen").tag(days)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Personendaten automatisch entfernen").font(.headline)
                        Text("Bei beendeten Einsätzen: Namen, Geburtsdatum, Merkmale, Freitext.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            } header: {
                Text("Datenschutz")
            } footer: {
                Text("Sichtung, Verletzungen, Verbleib und Zeiten bleiben für Bericht und Statistik. Gilt auch für geteilte Einsätze. Einzelne Einsätze: in der Einsatzliste lange drücken › „Personendaten entfernen“.")
            }
            Section {
                ForEach(OpenItem.Kind.allCases, id: \.key) { kind in
                    Toggle(kind.settingsTitle, isOn: Binding(
                        get: { !settings.reminders.hiddenOpenItemKinds.contains(kind.key) },
                        set: { shown in
                            save { settings in
                                var hidden = Set(settings.reminders.hiddenOpenItemKinds)
                                if shown { hidden.remove(kind.key) } else { hidden.insert(kind.key) }
                                settings.reminders.hiddenOpenItemKinds = hidden.sorted()
                            }
                        }
                    ))
                    .frame(minHeight: TouchTarget.minimum)
                }
            } header: {
                Text("Offene Punkte")
            } footer: {
                Text("Ausgeschaltete Arten erscheinen weder in der Lage noch als Hinweis oder Mitteilung. Einzelne Punkte lassen sich in der Lage mit ✓ als „zur Kenntnis genommen“ abhaken.")
            }
            Section {
                Picker(selection: Binding(
                    get: { settings.triageAlgorithm },
                    set: { value in save { $0.triageAlgorithm = value } }
                )) {
                    ForEach(TriageAlgorithm.allCases) { algorithm in
                        Text(algorithm.displayName).tag(algorithm)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sichtungsalgorithmus").font(.headline)
                        Text(settings.triageAlgorithm.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            } header: {
                Text("Geführte Sichtung")
            } footer: {
                Text("„Sichtungshilfe“ beim Patienten fragt Schritt für Schritt und schlägt eine Kategorie vor. Übernommen wird sie erst per Tipp; Antworten stehen im Protokoll.")
            }
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
                minutesPicker("Nachsichtung SK 2 alle", value: settings.reminders.retriageMinutesSK2) { value in
                    save { $0.reminders.retriageMinutesSK2 = value }
                }
                minutesPicker("Nachsichtung SK 3 alle", value: settings.reminders.retriageMinutesSK3) { value in
                    save { $0.reminders.retriageMinutesSK3 = value }
                }
                Toggle(isOn: Binding(
                    get: { settings.reminders.notifiesWhenLocked },
                    set: { on in save { $0.reminders.notifiesWhenLocked = on } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mitteilungen mit Ton").font(.headline)
                        Text("Neue offene Punkte und fällige Erinnerungen als Mitteilung mit Ton – auch bei offener App und auf dem Sperrbildschirm, ohne Patientennamen.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
                Toggle(isOn: Binding(
                    get: { settings.showsLiveActivity },
                    set: { on in save { $0.showsLiveActivity = on } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live-Aktivität").font(.headline)
                        Text("Laufzeit, SK-Zähler und nächste Lagemeldung auf dem Sperrbildschirm (iPhone; iPad ab iPadOS 26).")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: TouchTarget.comfortable)
            } header: {
                Text("Erinnerungen")
            } footer: {
                Text("Erscheinen unter „Offene Punkte“ in der Lage; neue Punkte zusätzlich als Hinweis oben. „Aus“ schaltet die Erinnerung ab.")
            }

            Section {
                Picker("Lagebild ins Tagebuch alle", selection: Binding(
                    get: { settings.reminders.situationSnapshotMinutes },
                    set: { value in save { $0.reminders.situationSnapshotMinutes = value } }
                )) {
                    ForEach(ReminderSettings.snapshotChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Aus" : "\(minutes) min").tag(minutes)
                    }
                }
                .frame(minHeight: TouchTarget.minimum)
            } header: {
                Text("Automatische Lagebilder")
            } footer: {
                Text("Im Takt ein Eintrag im Tagebuch: Kartenbild um den Einsatzort mit Markierungen, dazu SK-Zahlen, Transporte und Einheiten – ohne Patientennamen. Im geteilten Einsatz erstellt nur das Gerät der Einsatzleitung die Lagebilder.")
            }

            Section {
                ForEach(settings.effectiveMissionTypes) { entry in
                    // Name oben, Zuordnung darunter linksbündig – passt auch aufs iPhone.
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(entry.type.displayName).font(.headline)
                        Menu {
                            Picker("Checkliste", selection: Binding(
                                get: { entry.checklistID },
                                set: { id in updateTypes { types in
                                    if let index = types.firstIndex(where: { $0.id == entry.id }) { types[index].checklistID = id }
                                } }
                            )) {
                                Text("Standard (wie ohne Einsatzart)").tag(String?.none)
                                ForEach(lists) { list in Text(list.name).tag(Optional(list.id)) }
                            }
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "checklist")
                                Text("Checkliste: \(entry.checklistID.flatMap { id in lists.first { $0.id == id }?.name } ?? "Standard")")
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        // Schritt 106: Vorlage (Abschnitte, Alarmstichwort).
                        Button { editingTemplate = entry.id } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "square.stack.3d.up")
                                Text(templateSummary(entry)).lineLimit(1)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, Spacing.xxs)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum, alignment: .leading)
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
        .sheet(item: Binding(
            get: { editingTemplate.flatMap { id in store?.settings.effectiveMissionTypes.first { $0.id == id } } },
            set: { if $0 == nil { editingTemplate = nil } }
        )) { entry in
            MissionTypeTemplateEditor(entry: entry) { updated in
                updateTypes { types in
                    if let index = types.firstIndex(where: { $0.id == updated.id }) { types[index] = updated }
                }
            }
        }
    }

    private func templateSummary(_ entry: MissionTypeSetting) -> String {
        guard entry.hasTemplate else { return "Vorlage: keine" }
        var parts: [String] = []
        if let stichwort = entry.alarmstichwort { parts.append(stichwort.rawValue) }
        let sections = entry.templateSections
        if !sections.isEmpty { parts.append(sections.count == 1 ? "1 Abschnitt" : "\(sections.count) Abschnitte") }
        return "Vorlage: " + parts.joined(separator: " · ")
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

/// Vorlage einer Einsatzart (Schritt 106): Alarmstichwort und zusätzliche Abschnitte,
/// die „Neuer Einsatz“ automatisch übernimmt.
struct MissionTypeTemplateEditor: View {
    let entry: MissionTypeSetting
    let onSave: (MissionTypeSetting) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stichwort: Alarmstichwort?
    @State private var sectionsText: String
    @State private var initial: String

    init(entry: MissionTypeSetting, onSave: @escaping (MissionTypeSetting) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _stichwort = State(initialValue: entry.alarmstichwort)
        _sectionsText = State(initialValue: entry.templateSections.joined(separator: "\n"))
        _initial = State(initialValue: entry.initialSectionName ?? "")
    }

    private var sections: [String] {
        var seen = Set<String>()
        return sectionsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Alarmstichwort", selection: $stichwort) {
                        Text("Ohne").tag(Alarmstichwort?.none)
                        ForEach(Alarmstichwort.allCases) { value in
                            Text("\(value.rawValue) – \(value.summary)").tag(Optional(value))
                        }
                    }
                    .frame(minHeight: TouchTarget.minimum)
                } footer: {
                    Text("Wird bei „Neuer Einsatz“ vorgewählt, wenn diese Einsatzart gewählt wird; lässt sich dort ändern.")
                }
                Section {
                    TextEditor(text: $sectionsText)
                        .frame(minHeight: 140)
                        .font(.body)
                } header: {
                    Text("Zusätzliche Abschnitte – einer je Zeile")
                } footer: {
                    Text("Kommen zu den Abschnitten aus den Stammdaten dazu, z. B. „Atemschutz-Sammelplatz“, „Dekon“, „Verletztenablage“.")
                }
                Section("Initialabschnitt") {
                    Picker("Initialabschnitt", selection: $initial) {
                        Text("Wie in den Stammdaten").tag("")
                        ForEach(sections, id: \.self) { name in Text(name).tag(name) }
                    }
                    .frame(minHeight: TouchTarget.minimum)
                }
            }
            .navigationTitle("Vorlage \(entry.type.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        var updated = entry
                        updated.alarmstichwort = stichwort
                        updated.sectionNames = sections.isEmpty ? nil : sections
                        updated.initialSectionName = sections.contains(initial) ? initial : nil
                        onSave(updated)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
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

/// Führungspersonal (Schritt 81): Name, Funkrufname, Kanal und passende Funktionen.
struct LeadershipPeopleSettingsView: View {
    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var errorMessage: String?

    var body: some View {
        let people = store?.settings.leadershipPeople ?? []
        List {
            Section {
                if people.isEmpty {
                    Text("Noch niemand eingetragen.").foregroundStyle(.secondary)
                }
                ForEach(people) { person in
                    NavigationLink {
                        LeadershipPersonEditor(personID: person.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name.isEmpty ? "Ohne Namen" : person.name).font(.headline)
                            Text(detail(person)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: TouchTarget.minimum, alignment: .leading)
                    }
                }
                .onDelete { offsets in
                    save { $0.leadershipPeople.remove(atOffsets: offsets) }
                }
                Button {
                    save { $0.leadershipPeople.append(LeadershipPerson(name: "Neue Person")) }
                } label: {
                    Label("Person hinzufügen", systemImage: "plus")
                }
            } footer: {
                Text("In „Führung und Kräfte“ lassen sich diese Personen per Tipp übernehmen; Freitext bleibt möglich.")
            }
            // Schritt 99: weitere Nummern fürs Telefonbuch.
            Section {
                ForEach(store?.settings.phoneBook ?? []) { entry in
                    PhoneEntryRow(entry: entry) { updated in
                        save { settings in
                            guard let index = settings.phoneBook.firstIndex(where: { $0.id == updated.id }) else { return }
                            settings.phoneBook[index] = updated
                        }
                    }
                }
                .onDelete { offsets in save { $0.phoneBook.remove(atOffsets: offsets) } }
                Button {
                    save { $0.phoneBook.append(PhoneEntry(name: "", number: "")) }
                } label: {
                    Label("Nummer hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Telefonbuch")
            } footer: {
                Text("Z. B. ILS, Polizei, Feuerwehr-Einsatzleitung. Im Einsatz unter „Lage › Telefonbuch“ zusammen mit Führungspersonal und Kliniken aus den Stammdaten.")
            }
        }
        .navigationTitle("Führungspersonal")
        .settingsError($errorMessage)
    }


    private func detail(_ person: LeadershipPerson) -> String {
        let roles = person.roles.isEmpty ? "alle Funktionen" : person.roles.map(\.shortName).joined(separator: ", ")
        return [roles, person.callsign, person.radioChannel].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func save(_ change: (inout AppSettings) -> Void) {
        do { try store?.update(change) } catch { errorMessage = ErrorText.message(for: error) }
    }
}

struct LeadershipPersonEditor: View {
    let personID: UUID

    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var draft: LeadershipPerson?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let binding = Binding($draft) {
                Section {
                    TextField("Name", text: binding.name).frame(minHeight: TouchTarget.minimum)
                    TextField("Funkrufname", text: binding.callsign).frame(minHeight: TouchTarget.minimum)
                    TextField("Funkkanal (z. B. TMO 312)", text: binding.radioChannel).frame(minHeight: TouchTarget.minimum)
                    TextField("Telefon", text: Binding(get: { binding.wrappedValue.phone ?? "" }, set: { binding.wrappedValue.phone = $0 }))
                        .keyboardType(.phonePad)
                        .frame(minHeight: TouchTarget.minimum)
                }
                Section {
                    ForEach(LeadershipRole.allCases) { role in
                        Toggle(role.displayName, isOn: Binding(
                            get: { binding.wrappedValue.roles.contains(role) },
                            set: { on in
                                binding.wrappedValue.roles.removeAll { $0 == role }
                                if on { binding.wrappedValue.roles.append(role) }
                            }
                        ))
                        .frame(minHeight: TouchTarget.minimum)
                    }
                } header: {
                    Text("Funktionen")
                } footer: {
                    Text("Keine Auswahl = kommt für alle Funktionen in Frage. Abschnittsleitungen können immer alle übernehmen.")
                }
            }
        }
        .navigationTitle(draft?.name.isEmpty == false ? draft!.name : "Person")
        .onAppear {
            if draft == nil { draft = store?.settings.leadershipPeople.first { $0.id == personID } }
        }
        .onDisappear(perform: commit)
        .settingsError($errorMessage)
    }

    private func commit() {
        guard let draft else { return }
        let cleaned = LeadershipPerson(id: draft.id, name: draft.name, callsign: draft.callsign, radioChannel: draft.radioChannel, roles: draft.roles, phone: draft.phone)
        do {
            try store?.update { settings in
                guard let index = settings.leadershipPeople.firstIndex(where: { $0.id == cleaned.id }) else { return }
                settings.leadershipPeople[index] = cleaned
            }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}


/// Name und Nummer eines Telefonbuch-Eintrags, gespeichert beim Verlassen des Felds.
private struct PhoneEntryRow: View {
    let entry: PhoneEntry
    let onChange: (PhoneEntry) -> Void
    @State private var name: String
    @State private var number: String

    init(entry: PhoneEntry, onChange: @escaping (PhoneEntry) -> Void) {
        self.entry = entry
        self.onChange = onChange
        _name = State(initialValue: entry.name)
        _number = State(initialValue: entry.number)
    }

    var body: some View {
        HStack {
            TextField("Name (z. B. ILS)", text: $name)
                .onSubmit(commit)
            TextField("Nummer", text: $number)
                .keyboardType(.phonePad)
                .multilineTextAlignment(.trailing)
                .onSubmit(commit)
        }
        .frame(minHeight: TouchTarget.minimum)
        .onDisappear(perform: commit)
        .onChange(of: name) { commit() }
        .onChange(of: number) { commit() }
    }

    private func commit() {
        guard name != entry.name || number != entry.number else { return }
        var updated = entry
        updated.name = name
        updated.number = number
        onChange(updated)
    }
}
