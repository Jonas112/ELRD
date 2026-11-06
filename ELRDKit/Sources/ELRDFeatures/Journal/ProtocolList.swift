import SwiftUI
import ELRDDomain
import ELRDStore

/// Filter für das Protokoll: Fachbereich und Suche.
struct ProtocolFilter: Equatable {
    var category: LogCategory?
    var search = ""

    func apply(to entries: [MissionLogEntry]) -> [MissionLogEntry] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            (category == nil || entry.category == category)
                && words.allSatisfy { entry.message.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Anzahl je Fachbereich (mit Suche), für die Kapseln.
    static func counts(_ entries: [MissionLogEntry], search: String) -> [LogCategory: Int] {
        let matching = ProtocolFilter(category: nil, search: search).apply(to: entries)
        return Dictionary(grouping: matching, by: \.category).mapValues(\.count)
    }
}

/// Protokoll (E55: Filter im Tagebuch): jede Aktion mit Zeit, Bereich und Person,
/// neueste zuerst. Nur lesen.
struct ProtocolList: View {
    let entries: [MissionLogEntry]
    let people: [PersonChoice]
    @Binding var filter: ProtocolFilter

    var body: some View {
        let counts = ProtocolFilter.counts(entries, search: filter.search)
        let shown = filter.apply(to: entries)
        VStack(alignment: .leading, spacing: Spacing.m) {
            UnitSearchField(text: $filter.search)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    FilterPill(title: "Alle \(counts.values.reduce(0, +))", isSelected: filter.category == nil) { filter.category = nil }
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        if (counts[category] ?? 0) > 0 || filter.category == category {
                            FilterPill(title: "\(category.displayName) \(counts[category] ?? 0)", isSelected: filter.category == category) {
                                filter.category = category
                            }
                        }
                    }
                }
            }
            if shown.isEmpty {
                Text(entries.isEmpty ? "Noch keine Einträge im Protokoll." : "Kein Eintrag passt zur Auswahl.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            }
            LazyVStack(spacing: 0) {
                ForEach(shown) { entry in
                    row(entry)
                    Divider()
                }
            }
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func row(_ entry: MissionLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message).fixedSize(horizontal: false, vertical: true)
                Text([entry.category.displayName, authorName(entry)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .combine)
    }

    private func authorName(_ entry: MissionLogEntry) -> String? {
        guard let author = entry.authorID else { return nil }
        return people.first { $0.id == author }?.name
    }
}
