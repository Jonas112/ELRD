import SwiftUI
import ELRDDomain
import ELRDStore

/// Statistik über alle Einsätze (Schritt 100): je Jahr oder gesamt, Übungen getrennt.
struct StatisticsSheet: View {
    let model: MissionListModel

    @Environment(\.dismiss) private var dismiss
    @State private var year: Int? = Calendar.current.component(.year, from: Date())

    var body: some View {
        let stats = model.statistics(year: year)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.s) {
                            ChoiceChip("Alle Jahre", isSelected: year == nil) { year = nil }
                            ForEach(yearChoices(stats), id: \.self) { value in
                                ChoiceChip(String(value), isSelected: year == value) { year = value }
                            }
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Spacing.m)], spacing: Spacing.m) {
                        tile("Einsätze", "\(stats.missions)", stats.running > 0 ? "davon \(stats.running) laufend" : nil)
                        tile("Patienten", "\(stats.patients)", stats.largestPatients > 0 ? "größter Einsatz \(stats.largestPatients)" : nil)
                        tile("Ø Dauer", stats.averageMinutes.map(duration) ?? "–", stats.longestMinutes.map { "längster \(duration($0))" })
                        tile("Übungen", "\(stats.exercises)", "nicht mitgezählt")
                    }
                    if stats.patients > 0 {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("Patienten nach Sichtungskategorie").font(.headline)
                            HStack(spacing: Spacing.s) {
                                ForEach([Sichtungskategorie.sk1, .sk2, .sk3, .ungesichtet, .unverletzt, .verstorben], id: \.self) { triage in
                                    let count = stats.triageCounts[triage] ?? 0
                                    if count > 0 {
                                        VStack(spacing: 0) {
                                            Text(triage.shortName).font(.caption.weight(.bold))
                                            Text("\(count)").font(.title3.weight(.heavy).monospacedDigit())
                                        }
                                        .foregroundStyle(Color.onTriage(triage))
                                        .frame(maxWidth: .infinity, minHeight: 56)
                                        .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                                    }
                                }
                            }
                        }
                        .cardStyle()
                    }
                    if !stats.byType.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("Nach Einsatzart").font(.headline)
                            ForEach(stats.byType, id: \.name) { row in
                                HStack {
                                    Text(row.name)
                                    Spacer()
                                    Text("\(row.missions == 1 ? "1 Einsatz" : "\(row.missions) Einsätze") · \(row.patients == 1 ? "1 Patient" : "\(row.patients) Patienten")")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minHeight: TouchTarget.minimum)
                            }
                        }
                        .cardStyle()
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(Surface.canvas)
            .navigationTitle("Statistik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
        }
    }

    private func yearChoices(_ stats: MissionStatistics) -> [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array(Set(stats.years + [current])).sorted(by: >)
    }

    private func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%d:%02d h", minutes / 60, minutes % 60)
    }

    private func tile(_ title: String, _ value: String, _ caption: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.heavy).monospacedDigit())
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Personensuche über alle Einsätze (Schritt 101) – Verbleib auch nach Einsatzende.
struct PersonSearchSheet: View {
    let model: MissionListModel
    let onOpenMission: (MissionID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [PersonSearchHit] = []

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text("Name, Patientennummer oder Anhängekarte eingeben (mindestens 2 Zeichen).")
                        .foregroundStyle(.secondary)
                } else if hits.isEmpty {
                    Text("Kein Treffer in den Einsätzen auf diesem Gerät.").foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    Button {
                        dismiss()
                        onOpenMission(hit.missionID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Spacing.s) {
                                Text(hit.whereabouts.triage.shortName)
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(Color.onTriage(hit.whereabouts.triage))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.triage(hit.whereabouts.triage), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                                Text(hit.whereabouts.name.isEmpty ? "Name unbekannt" : hit.whereabouts.name).font(.headline)
                                Text(hit.whereabouts.number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text("\(hit.isExercise ? "ÜBUNG " : "")\(hit.missionNumber) · \(hit.missionTitle) · \(hit.startedAt.formatted(date: .numeric, time: .shortened))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(hit.whereabouts.detail.isEmpty ? hit.whereabouts.whereabouts : "\(hit.whereabouts.whereabouts) – \(hit.whereabouts.detail)")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(minHeight: TouchTarget.comfortable, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, Nummer oder Anhängekarte")
            .onChange(of: query) { hits = model.searchPersons(query) }
            .navigationTitle("Personensuche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
        }
    }
}
