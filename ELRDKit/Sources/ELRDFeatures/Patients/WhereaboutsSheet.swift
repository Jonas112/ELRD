import SwiftUI
import ELRDDomain
import ELRDStore
import ELRDReports

/// Verbleibsliste / Personenauskunft (Schritt 93): Suche nach Name, Nummer oder
/// Anhängekarte → wo ist der Patient. Als PDF teilbar (mit Datenschutzhinweis).
struct WhereaboutsSheet: View {
    let store: MissionStore
    var onOpen: (PatientID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @State private var query = ""
    @State private var filter: PatientWhereabouts.Place?
    @State private var shareURL: URL?

    var body: some View {
        let all = PatientWhereabouts.list(
            patients: store.state.patients,
            units: store.state.units,
            sections: store.state.sections,
            now: Date()
        )
        let shown = all.filter { (filter == nil || $0.place == filter) && (query.isEmpty || $0.matches(query)) }
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.s) {
                            FilterPill(title: "Alle \(all.count)", isSelected: filter == nil) { filter = nil }
                            ForEach([PatientWhereabouts.Place.onScene, .transported, .released, .deceased], id: \.self) { place in
                                let count = all.filter { $0.place == place }.count
                                if count > 0 {
                                    FilterPill(title: "\(title(place)) \(count)", isSelected: filter == place) {
                                        filter = filter == place ? nil : place
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    if shown.isEmpty {
                        Text(all.isEmpty ? "Noch keine Patienten erfasst." : "Kein Treffer für „\(query)“.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown) { entry in
                        Button {
                            dismiss()
                            onOpen(entry.id)
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Enthält personenbezogene Daten – nur an berechtigte Stellen (z. B. Personenauskunftsstelle, Polizei) weitergeben.")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, Nummer oder Anhängekarte")
            .navigationTitle("Verbleib")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
                ToolbarItem(placement: .primaryAction) {
                    if let shareURL {
                        ShareLink(item: shareURL) { Label("Als PDF teilen", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .task(id: store.state.patients.count) { makePDF(all) }
        }
    }

    private func row(_ entry: PatientWhereabouts) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(entry.triage.shortName)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Color.onTriage(entry.triage))
                .frame(width: 52, height: 32)
                .background(Color.triage(entry.triage), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.s) {
                    Text(entry.number).font(.headline.monospacedDigit())
                    Text(entry.name.isEmpty ? "Name unbekannt" : entry.name)
                        .font(.headline)
                        .foregroundStyle(entry.name.isEmpty ? .secondary : .primary)
                }
                let person = [entry.birth, entry.tagNumber.map { "Karte \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !person.isEmpty { Text(person).font(.subheadline).foregroundStyle(.secondary) }
                Label(entry.whereabouts, systemImage: icon(entry.place))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.place == .transported ? Color.accentColor : .primary)
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func title(_ place: PatientWhereabouts.Place) -> String {
        switch place {
        case .onScene: "Vor Ort"
        case .transported: "Transportiert"
        case .released: "Entlassen"
        case .deceased: "Verstorben"
        }
    }

    private func icon(_ place: PatientWhereabouts.Place) -> String {
        switch place {
        case .onScene: "mappin.and.ellipse"
        case .transported: "cross.case.fill"
        case .released: "figure.walk"
        case .deceased: "heart.slash"
        }
    }

    private func makePDF(_ entries: [PatientWhereabouts]) {
        let settings = appSettings?.settings ?? AppSettings()
        let theme = ReportTheme(logo: settings.bannerImage, bannerText: settings.organisationName)
        let data = WhereaboutsReport.pdf(
            mission: store.state.mission,
            entries: entries,
            createdAt: Date(),
            createdBy: store.sessionDisplayName,
            theme: theme
        )
        let name = "Verbleibsliste \(store.state.mission.displayNumber().replacingOccurrences(of: "/", with: "-")).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            shareURL = nil
        }
    }
}
