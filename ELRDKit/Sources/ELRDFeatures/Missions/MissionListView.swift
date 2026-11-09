import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ELRDDomain
import ELRDStore
import ELRDCloud

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
    @State private var showsNearby = false
    @State private var showsJoin = false
    /// Schritte 100, 101.
    @State private var showsStatistics = AppLaunchOptions.current.demoScreen == .statistics
    @State private var showsPersonSearch = false
    /// Schritt 102.
    @State private var pendingAnonymize: MissionSummary?
    @Environment(CloudSyncCoordinator.self) private var cloud: CloudSyncCoordinator?
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
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
                    banner
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
                    Menu {
                        Button("Einsatz aus Datei öffnen …", systemImage: "doc") { showsImporter = true }
                        Button("Einsatz von iPad in der Nähe übernehmen …", systemImage: "arrow.triangle.2.circlepath") { showsNearby = true }
                        if cloud != nil {
                            Button("Geteiltem Einsatz beitreten (iCloud-Link) …", systemImage: "person.2.badge.plus") { showsJoin = true }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title3.weight(.semibold))
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    }
                    .accessibilityLabel("Einsatz übernehmen")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Statistik", systemImage: "chart.bar") { showsStatistics = true }
                        Button("Personensuche (alle Einsätze)", systemImage: "person.text.rectangle") { showsPersonSearch = true }
                    } label: {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.title3.weight(.semibold))
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    }
                    .accessibilityLabel("Statistik und Personensuche")
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
        .background { extrasHost }
        .sheet(isPresented: $showsNearby) {
            NearbySyncView(session: makeNearbySession())
        }
        .sheet(isPresented: $showsJoin) {
            if let cloud {
                JoinCloudMissionSheet(cloud: cloud) { mission in
                    model.reload()
                    do { onOpen(try model.open(mission)) } catch { actionError = ErrorText.message(for: error) }
                }
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.loadError != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.loadError ?? "")
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

    /// Banner/Logo und Organisation aus den Einstellungen (Allgemein).
    @ViewBuilder
    private var banner: some View {
        let settings = appSettings?.settings ?? AppSettings()
        if let data = settings.bannerImage, let image = UIImage(data: data) {
            HStack(spacing: Spacing.l) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 72)
                    .accessibilityHidden(true)
                if !settings.organisationName.isEmpty {
                    Text(settings.organisationName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(settings.organisationName.isEmpty ? "Banner" : settings.organisationName)
        }
    }

    private var purgeTitle: String {
        guard let pendingPurge else { return "Endgültig löschen?" }
        return "Einsatz \(pendingPurge.displayNumber) endgültig löschen?"
    }

    /// Einsatz von einem iPad in der Nähe übernehmen (Schritt 66).
    private func makeNearbySession() -> NearbySyncSession {
        let session = NearbySyncSession(
            displayName: model.session.displayName,
            missionID: nil,
            missionTitle: "",
            makeExchange: { [model] id in model.makeNearbyExchange(id) }
        )
        session.onImported = { [model] in model.reload() }
        return session
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
                    yearPicker(width: 180)
                }
                VStack(alignment: .leading, spacing: Spacing.m) {
                    sectionTitle
                    HStack(spacing: Spacing.m) {
                        searchField
                        yearPicker(width: 180)
                    }
                }
                // iPhone: Suche über die ganze Breite, Zeitraum darunter.
                VStack(alignment: .leading, spacing: Spacing.m) {
                    sectionTitle
                    searchField
                    yearPicker(width: nil)
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
                                if model.canCreate, !summary.isAnonymized {
                                    Button("Personendaten entfernen …", systemImage: "person.crop.circle.badge.xmark") { pendingAnonymize = summary }
                                }
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

    private func yearPicker(width: CGFloat?) -> some View {
        Picker("Zeitraum", selection: $showsAllYears) {
            Text(String(Calendar.current.component(.year, from: model.now()))).tag(false)
            Text("Alle").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
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

    /// Schritte 100–102: Dialoge und Blätter an einer eigenen, unsichtbaren Ansicht –
    /// sonst wird `body` für den Compiler zu lang.
    private var extrasHost: some View {
        Color.clear
            .confirmationDialog(
            "Personendaten entfernen?",
            isPresented: Binding(get: { pendingAnonymize != nil }, set: { if !$0 { pendingAnonymize = nil } }),
            titleVisibility: .visible,
            presenting: pendingAnonymize
        ) { summary in
            Button("Namen und Personendaten entfernen", role: .destructive) {
                do { try model.anonymize(summary.id) } catch { actionError = ErrorText.message(for: error) }
            }
        } message: { _ in
            Text("Namen, Geburtsdaten, Merkmale und Freitext der Patienten werden gelöscht – auch bei allen, die den Einsatz teilen. Sichtung, Verletzungen, Verbleib und Zeiten bleiben. Lässt sich nicht rückgängig machen.")
        }
            .task(id: appSettings?.settings.anonymizeAfterDays ?? 0) {
            model.anonymizeDue(afterDays: appSettings?.settings.anonymizeAfterDays ?? 0)
        }
            .sheet(isPresented: $showsStatistics) {
            StatisticsSheet(model: model).largeSheet()
        }
            .sheet(isPresented: $showsPersonSearch) {
            PersonSearchSheet(model: model) { mission in
                do { onOpen(try model.open(mission)) } catch { actionError = ErrorText.message(for: error) }
            }
            .largeSheet()
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
            // iPhone: kleinerer Kreis und Rand, damit „Neuer Einsatz“ ganz lesbar bleibt.
            ViewThatFits(in: .horizontal) {
                content(circle: 92, titleSize: 34, spacing: Spacing.xl, padding: Spacing.xxl, minHeight: 200)
                content(circle: 64, titleSize: 30, spacing: Spacing.l, padding: Spacing.xl, minHeight: 150)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityHint("Legt einen neuen Einsatz an")
    }

    private func content(circle: CGFloat, titleSize: CGFloat, spacing: CGFloat, padding: CGFloat, minHeight: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Image(systemName: "plus")
                .font(.system(size: circle * 0.48, weight: .bold))
                .frame(width: circle, height: circle)
                .background(.white.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Neuer Einsatz")
                    .font(.system(size: titleSize, weight: .heavy))
                    .lineLimit(1)
                    .fixedSize()
                Text(isEnabled ? "Stichwort, Einsatzart, Ort – alles Weitere später" : "Ohne Abo nur Ansehen und Export")
                    .font(.body)
                    .opacity(0.9)
                    // Feste Idealbreite: Die Wahl der Variante hängt nur am Titel.
                    .frame(idealWidth: 120, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, padding)
        .frame(minHeight: minHeight)
    }
}

/// Karte eines laufenden Einsatzes mit „Fortsetzen“.
struct RunningMissionCard: View {
    let summary: MissionSummary
    let now: () -> Date
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    runningLabel
                    Spacer()
                    elapsed
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    runningLabel
                    elapsed
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

    private var runningLabel: some View {
        Label {
            Text("LAUFENDER EINSATZ").font(.subheadline.weight(.bold)).tracking(0.8)
                .lineLimit(1)
                .fixedSize()
        } icon: {
            Circle().fill(.tint).frame(width: 10, height: 10)
        }
        .foregroundStyle(.tint)
    }

    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text("\(summary.isExercise ? "ÜBUNG · " : "")\(summary.displayNumber) · seit \(ElapsedTimeFormat.string(from: summary.startedAt, to: now()))")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
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
            // iPhone: Datum und Dauer unter den Titel statt in eine eigene Spalte.
            ViewThatFits(in: .horizontal) {
                wide
                narrow
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dateText: String { summary.startedAt.formatted(date: .numeric, time: .shortened) }

    private var durationText: String {
        "\(ElapsedTimeFormat.string(from: summary.startedAt, to: summary.endedAt ?? now())) · \(patientText)"
    }

    private var narrow: some View {
        HStack(spacing: Spacing.m) {
            MissionThumbnailView(file: summary.thumbnail, size: 48)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(dateText) · \(durationText)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var wide: some View {
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
                .frame(minWidth: 160, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Text(dateText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(durationText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
    }

    private var subtitle: String {
        [summary.isExercise ? "ÜBUNG" : "", summary.displayNumber, summary.location].filter { !$0.isEmpty }.joined(separator: " · ")
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

