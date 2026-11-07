import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ELRDDomain
import ELRDStore

/// Startbildschirm nach der Anmeldung: neuer Einsatz, laufender Einsatz, frühere Einsätze.
///
/// Wichtigstes zuerst und groß: „Neuer Einsatz“ und „Fortsetzen“ sind auch verschlafen
/// sofort zu treffen. Frühere Einsätze stehen darunter.
struct MissionListView: View {
    @Bindable var model: MissionListModel
    let account: AccountMenuModel
    let masterData: MasterDataEditor?
    let isAdmin: Bool
    let initialSettingsPage: SettingsView.Page?
    let onOpen: (MissionStore) -> Void
    @State private var showsSettings: Bool

    @State private var showsNewMission: Bool
    @State private var pendingDelete: MissionSummary?
    @State private var actionError: String?
    @State private var showsDeleted = false
    /// Einsatzdatei zum Teilen (Schritt 63).
    @State private var exportURL: ExportedFile?
    @State private var showsImporter = false
    @State private var pendingPurge: MissionSummary?
    @State private var importNotice: String?
    @AppStorage("missionList.showsAllYears") private var showsAllYears = false

    init(
        model: MissionListModel,
        account: AccountMenuModel,
        masterData: MasterDataEditor? = nil,
        isAdmin: Bool = false,
        showsNewMissionInitially: Bool = false,
        initialSettingsPage: SettingsView.Page? = nil,
        onOpen: @escaping (MissionStore) -> Void
    ) {
        self.model = model
        self.account = account
        self.masterData = masterData
        self.isAdmin = isAdmin
        self.initialSettingsPage = initialSettingsPage
        self.onOpen = onOpen
        _showsNewMission = State(initialValue: showsNewMissionInitially)
        _showsSettings = State(initialValue: initialSettingsPage != nil)
    }

    var body: some View {
        let result = model.result
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    topRow(running: result.running)
                    finishedSection(result)
                    if !model.deletedMissions.isEmpty { deletedSection }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.l)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .background(Surface.canvas)
            .navigationTitle("Einsätze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsImporter = true } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title3.weight(.semibold))
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    }
                    .accessibilityLabel("Einsatz aus Datei öffnen")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title3.weight(.semibold))
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    }
                    .accessibilityLabel("Einstellungen")
                }
                // Die Navigationsleiste ist niedriger als 44 pt – ein größerer Kreis würde oben und unten abgeschnitten.
                ToolbarItem(placement: .topBarTrailing) { AccountAvatarMenu(account: account, size: 34) }
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(masterData: masterData, isAdmin: isAdmin, initialPage: initialSettingsPage) { showsSettings = false }
                .largeSheet()
        }
        .onAppear { model.filter.showsAllYears = showsAllYears }
        .onChange(of: showsAllYears) { _, value in model.filter.showsAllYears = value }
        // Bildschirmfüllend: große Ziele, nichts muss gescrollt werden.
        .fullScreenCover(isPresented: $showsNewMission) {
            NewMissionView(commanderName: model.session.displayName) { form in
                let store = try model.create(form)
                showsNewMission = false
                onOpen(store)
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { summary in
            Button("Einsatz löschen", role: .destructive) { delete(summary) }
        } message: { _ in
            Text("Der Einsatz verschwindet aus der Liste und lässt sich unter „Gelöscht“ wiederherstellen.")
        }
        .alert("Aktion nicht möglich", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        // Schritt 63: Einsatz als Datei teilen, öffnen, endgültig löschen.
        .sheet(item: $exportURL) { file in
            ActivityView(items: [file.url])
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data, .json]) { result in
            switch result {
            case .success(let url): importArchive(url)
            case .failure(let error): actionError = ErrorText.message(for: error)
            }
        }
        .onOpenURL { url in
            if url.pathExtension == MissionArchive.fileExtension { importArchive(url) }
        }
        .alert("Einsatz übernommen", isPresented: Binding(get: { importNotice != nil }, set: { if !$0 { importNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importNotice ?? "")
        }
        .confirmationDialog(
            purgeTitle,
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            titleVisibility: .visible,
            presenting: pendingPurge
        ) { summary in
            Button("Endgültig löschen", role: .destructive) { purge(summary) }
        } message: { _ in
            Text("Alle Daten, Fotos und Sprachnotizen dieses Einsatzes werden von diesem iPad entfernt. Das lässt sich nicht rückgängig machen.")
        }
    }

    private var purgeTitle: String {
        guard let pendingPurge else { return "Endgültig löschen?" }
        return "Einsatz \(pendingPurge.displayNumber) endgültig löschen?"
    }

    private func exportArchive(_ summary: MissionSummary) {
        do {
            exportURL = ExportedFile(url: try model.exportFile(summary.id))
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    private func importArchive(_ url: URL) {
        do {
            let result = try model.importFile(url)
            let title = model.missions.first { $0.id == result.missionID }.map { "\($0.displayNumber) „\($0.title)“" } ?? "Der Einsatz"
            var text = result.imported.newEvents == 0
                ? "\(title) war schon auf dem neuesten Stand."
                : "\(title) ist jetzt auf diesem iPad."
            if result.filesRejected > 0 { text += " \(result.filesRejected) Datei(en) waren beschädigt und fehlen." }
            importNotice = text
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    private func purge(_ summary: MissionSummary) {
        do {
            try model.purge(summary.id)
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    private var deleteTitle: String {
        guard let pendingDelete else { return "Einsatz löschen?" }
        return "Einsatz \(pendingDelete.displayNumber) „\(pendingDelete.title)“ löschen?"
    }

    // MARK: Oben: Neuer Einsatz + laufender Einsatz

    @ViewBuilder
    private func topRow(running: [MissionSummary]) -> some View {
        // Nebeneinander, wenn genug Platz ist (iPad quer), sonst untereinander.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.xl) {
                newMissionButton.frame(minWidth: 380)
                runningColumn(running).frame(minWidth: 380)
            }
            VStack(spacing: Spacing.l) {
                newMissionButton
                runningColumn(running)
            }
        }
    }

    private var newMissionButton: some View {
        NewMissionButton(isEnabled: model.canCreate) { showsNewMission = true }
    }

    @ViewBuilder
    private func runningColumn(_ running: [MissionSummary]) -> some View {
        if running.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label("Kein laufender Einsatz", systemImage: "moon.zzz")
                    .font(.title3.weight(.semibold))
                Text("Ein neuer Einsatz startet sofort – Stichwort, Einsatzart und Ort reichen.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
            .padding(Spacing.xl)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            VStack(spacing: Spacing.l) {
                ForEach(running) { summary in
                    RunningMissionCard(summary: summary, now: model.now) { open(summary.id) }
                        .contextMenu {
                            // Übergabe an ein anderes iPad ohne Server (Schritt 63).
                            Button("Als Datei teilen …", systemImage: "square.and.arrow.up") { exportArchive(summary) }
                        }
                }
            }
        }
    }

    // MARK: Frühere Einsätze

    @ViewBuilder
    private func finishedSection(_ result: MissionListFilter.Result) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.m) {
                    sectionTitle
                    Spacer(minLength: Spacing.l)
                    searchField.frame(width: 320)
                    yearPicker
                }
                VStack(alignment: .leading, spacing: Spacing.m) {
                    sectionTitle
                    HStack(spacing: Spacing.m) {
                        searchField
                        yearPicker
                    }
                }
            }

            if result.finished.isEmpty {
                emptyFinished(result)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(result.finished.enumerated()), id: \.element.id) { index, summary in
                        if index > 0 { Divider().padding(.leading, Spacing.xl) }
                        FinishedMissionRow(summary: summary, now: model.now) { open(summary.id) }
                            .contextMenu {
                                Button("Als Datei teilen …", systemImage: "square.and.arrow.up") { exportArchive(summary) }
                                if model.canCreate {
                                    Button("Löschen …", systemImage: "trash", role: .destructive) { pendingDelete = summary }
                                }
                            }
                    }
                }
                .background(Surface.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    // MARK: Gelöschte Einsätze (Schritt 54)

    private var deletedSection: some View {
        DisclosureGroup(isExpanded: $showsDeleted) {
            VStack(spacing: 0) {
                ForEach(Array(model.deletedMissions.enumerated()), id: \.element.id) { index, summary in
                    if index > 0 { Divider().padding(.leading, Spacing.l) }
                    HStack(spacing: Spacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(summary.displayNumber) · \(summary.title)").font(.headline)
                            Text(summary.startedAt.formatted(date: .numeric, time: .shortened))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Spacing.m)
                        if model.canCreate {
                            Button("Wiederherstellen") { restore(summary) }
                                .font(.headline)
                                .frame(minHeight: TouchTarget.comfortable)
                            Button(role: .destructive) { pendingPurge = summary } label: {
                                Image(systemName: "trash.slash")
                                    .font(.headline)
                                    .frame(width: TouchTarget.comfortable, height: TouchTarget.comfortable)
                            }
                            .accessibilityLabel("Endgültig löschen")
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: TouchTarget.comfortable)
                }
            }
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.top, Spacing.s)
        } label: {
            Label("Gelöscht (\(model.deletedMissions.count))", systemImage: "trash")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(minHeight: TouchTarget.minimum)
        }
    }

    private var sectionTitle: some View {
        Text("Frühere Einsätze").font(.title2.weight(.bold))
    }

    private var searchField: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Suchen: Ort, Stichwort, Nummer", text: $model.filter.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.filter.searchText.isEmpty {
                Button { model.filter.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: TouchTarget.minimum + 4)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var yearPicker: some View {
        Picker("Zeitraum", selection: $showsAllYears) {
            Text(String(Calendar.current.component(.year, from: model.now()))).tag(false)
            Text("Alle").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .controlSize(.large)
    }

    @ViewBuilder
    private func emptyFinished(_ result: MissionListFilter.Result) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if !model.filter.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Keine Einsätze zu „\(model.filter.searchText)“.").foregroundStyle(.secondary)
            } else if model.missions.isEmpty {
                Text("Noch keine Einsätze auf diesem Gerät.").foregroundStyle(.secondary)
            } else {
                Text("Keine beendeten Einsätze in diesem Jahr.").foregroundStyle(.secondary)
            }
            if result.hiddenByYear > 0 {
                Button("\(result.hiddenByYear) aus früheren Jahren anzeigen") { showsAllYears = true }
                    .font(.headline)
                    .frame(minHeight: TouchTarget.minimum)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Aktionen

    private func open(_ missionID: MissionID) {
        do {
            onOpen(try model.open(missionID))
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    private func restore(_ summary: MissionSummary) {
        do {
            try model.restore(summary.id)
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    private func delete(_ summary: MissionSummary) {
        do {
            try model.delete(summary.id)
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }
}

/// Große Fläche „Neuer Einsatz“.
struct NewMissionButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xl) {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .bold))
                    .frame(width: 92, height: 92)
                    .background(.white.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Neuer Einsatz")
                        .font(.system(size: 34, weight: .heavy))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(isEnabled ? "Stichwort, Einsatzart, Ort – alles Weitere später" : "Ohne Abo nur Ansehen und Export")
                        .font(.body)
                        .opacity(0.9)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.xxl)
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityHint("Legt einen neuen Einsatz an")
    }
}

/// Karte eines laufenden Einsatzes mit „Fortsetzen“.
struct RunningMissionCard: View {
    let summary: MissionSummary
    let now: () -> Date
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Label {
                    Text("LAUFENDER EINSATZ").font(.subheadline.weight(.bold)).tracking(0.8)
                } icon: {
                    Circle().fill(.tint).frame(width: 10, height: 10)
                }
                .foregroundStyle(.tint)
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text("\(summary.displayNumber) · seit \(ElapsedTimeFormat.string(from: summary.startedAt, to: now()))")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: Spacing.l) {
                MissionThumbnailView(file: summary.thumbnail, size: 88)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(summary.title)
                        .font(.title.weight(.bold))
                        .lineLimit(2)
                    if !summary.location.isEmpty {
                        Text(summary.location)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    TriageSummaryView(counts: summary.triageCounts)
                    Spacer(minLength: Spacing.l)
                    resumeButton
                }
                VStack(alignment: .leading, spacing: Spacing.m) {
                    TriageSummaryView(counts: summary.triageCounts)
                    resumeButton
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var resumeButton: some View {
        Button(action: resume) {
            Label("Fortsetzen", systemImage: "arrow.right")
                .labelStyle(TrailingIconLabelStyle())
                .font(.title3.weight(.bold))
                .padding(.horizontal, Spacing.xl)
                .frame(minHeight: TouchTarget.comfortable)
        }
        // Grau statt Blau: Blau bleibt der einen Hauptaktion „Neuer Einsatz“ vorbehalten.
        .buttonStyle(.bordered)
        .tint(.primary)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityLabel("Einsatz \(summary.title) fortsetzen")
    }
}

/// Zeile eines beendeten Einsatzes.
struct FinishedMissionRow: View {
    let summary: MissionSummary
    let now: () -> Date
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.l) {
                MissionThumbnailView(file: summary.thumbnail, size: 56)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(summary.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.l)
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Text(summary.startedAt.formatted(date: .numeric, time: .shortened))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(ElapsedTimeFormat.string(from: summary.startedAt, to: summary.endedAt ?? now())) · \(patientText)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        [summary.displayNumber, summary.location].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var patientText: String {
        switch summary.patientCount {
        case 0: "keine Patienten"
        case 1: "1 Patient"
        default: "\(summary.patientCount) Patienten"
        }
    }
}

/// Beschriftung mit Symbol rechts („Fortsetzen →“).
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.s) {
            configuration.title
            configuration.icon
        }
    }
}

/// Vorschaubild eines Einsatzes in der Liste (Foto oder Kartenausschnitt aus dem
/// Tagebuch). Ohne Bild ein ruhiges Symbol, damit die Zeilen gleich aussehen.
struct MissionThumbnailView: View {
    let file: FileAttachment?
    let size: CGFloat

    @Environment(\.attachmentStore) private var attachments
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "map")
                    .font(.system(size: size * 0.36, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .background(Surface.elevated)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .accessibilityHidden(true)
        .task(id: file?.id) {
            guard let file else {
                image = nil
                return
            }
            guard let loaded = attachments.data(for: file).flatMap(UIImage.init(data:)),
                  loaded.size.width > 0, loaded.size.height > 0 else {
                image = nil
                return
            }
            // Seitenverhältnis behalten, kurze Seite = Kachelgröße (wird danach beschnitten).
            let pixels = size * displayScale
            let scale = max(pixels / loaded.size.width, pixels / loaded.size.height)
            let target = CGSize(width: loaded.size.width * scale, height: loaded.size.height * scale)
            image = scale < 1 ? (loaded.preparingThumbnail(of: target) ?? loaded) : loaded
        }
    }
}

/// Datei zum Teilen (eindeutig für `sheet(item:)`).
struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Teilen-Menü (AirDrop, Dateien, Mail …).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

