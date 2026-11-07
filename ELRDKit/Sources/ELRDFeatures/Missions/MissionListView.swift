import SwiftUI
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
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title3.weight(.semibold))
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    }
                    .accessibilityLabel("Einstellungen")
                }
                ToolbarItem(placement: .topBarTrailing) { AccountAvatarMenu(account: account, size: TouchTarget.minimum) }
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
            Text("Der Einsatz verschwindet aus der Liste. Die Daten bleiben für die Synchronisation erhalten.")
        }
        .alert("Aktion nicht möglich", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
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
            actionError = error.localizedDescription
        }
    }

    private func delete(_ summary: MissionSummary) {
        do {
            try model.delete(summary.id)
        } catch {
            actionError = error.localizedDescription
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
            .padding(.horizontal, Spacing.xl)
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
