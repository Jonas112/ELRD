import SwiftUI
import ELRDDomain
import ELRDStore

/// Arbeitsbereich eines Einsatzes: Seitenleiste mit Bereichen, rechts der Inhalt.
///
/// Passt sich an alle iPad-Größen an: Bei normaler Breite stehen Seitenleiste und
/// Inhalt nebeneinander; in schmalen Fenstern (Slide Over, ⅓ Split View, Stage
/// Manager klein) wird daraus automatisch eine Stapel-Navigation.
public struct MissionWorkspaceView: View {
    let store: MissionStore
    let account: AccountMenuModel?
    let onClose: (() -> Void)?

    @State private var selection: WorkspaceSection = .overview
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(store: MissionStore, account: AccountMenuModel? = nil, onClose: (() -> Void)? = nil) {
        self.store = store
        self.account = account
        self.onClose = onClose
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(state: store.state, selection: $selection, account: account, onClose: onClose)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                WorkspaceDetail(section: selection, store: store)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.workspaceSelection, $selection)
    }
}

/// Seitenleiste: Einsatzkopf, SK-Zähler, Bereiche.
struct WorkspaceSidebar: View {
    let state: MissionState
    @Binding var selection: WorkspaceSection
    var account: AccountMenuModel? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        let badges = WorkspaceBadges(state: state)
        List(selection: Binding<WorkspaceSection?>(
            get: { selection },
            set: { if let value = $0 { selection = value } }
        )) {
            Section {
                MissionHeader(mission: state.mission)
                TriageSummaryView(counts: Patient.countsByTriage(state.patients))
                    .padding(.vertical, Spacing.xs)
            }
            Section("Einsatz") {
                ForEach(WorkspaceSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(badges.badge(for: section))
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(state.mission.displayNumber())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let onClose {
                    Button(action: onClose) {
                        Label("Einsätze", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .frame(minHeight: TouchTarget.minimum)
                    }
                    .accessibilityHint("Zurück zur Einsatzliste")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let account { AccountMenuButton(account: account) }
            }
        }
    }
}

/// Kopf der Seitenleiste mit Titel, Ort und Laufzeit bzw. „Beendet“.
struct MissionHeader: View {
    let mission: Mission

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(mission.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            if !mission.location.isEmpty {
                Label(mission.location, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // Laufzeit minütlich aktualisieren.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if mission.isClosed {
                    Label("Beendet", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Läuft seit \(ElapsedTimeFormat.string(from: mission.startedAt, to: context.date))",
                        systemImage: "clock"
                    )
                    .foregroundStyle(.tint)
                }
            }
            .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Inhalt des gewählten Bereichs. Die Bereiche entstehen in den folgenden Schritten.
struct WorkspaceDetail: View {
    let section: WorkspaceSection
    let store: MissionStore

    var body: some View {
        Group {
            switch section {
            case .overview:
                OverviewPlaceholder(state: store.state)
            default:
                ContentUnavailableView {
                    Label(section.title, systemImage: section.systemImage)
                } description: {
                    Text("Dieser Bereich wird in Schritt \(section.plannedStep) gebaut.")
                }
            }
        }
        .navigationTitle(section.title)
    }
}

/// Vorläufige Übersicht bis Schritt 37.
struct OverviewPlaceholder: View {
    let state: MissionState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Patienten").font(.headline)
                    TriageSummaryView(counts: Patient.countsByTriage(state.patients), showsEmpty: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Organisation").font(.headline)
                    Text("\(state.activeSections.count) Abschnitte · \(state.activeUnits.count) Einheiten")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }
            .padding(Spacing.l)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Surface.canvas)
    }
}

#Preview("Arbeitsbereich") {
    if let store = try? PreviewData.makeStore() {
        MissionWorkspaceView(store: store)
    }
}
