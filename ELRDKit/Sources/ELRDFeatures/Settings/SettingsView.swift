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
    enum Page: Hashable { case general, vehicleImages, masterData, ivena, subscription, agreements }

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
                Text("Oben links im Bericht. Am besten ein Logo mit hellem oder durchsichtigem Hintergrund.")
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

