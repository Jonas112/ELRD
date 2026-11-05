import SwiftUI
import ELRDDomain

/// RMI-Auswahl ohne Untermenü: Suchfeld, darunter direkt die Treffer.
struct RMIField: View {
    let catalog: RMICatalog?
    let code: Int?
    let onSelect: (Int?) -> Void

    @State private var search = ""
    @FocusState private var focused: Bool

    static let maxResults = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let code {
                HStack(spacing: Spacing.m) {
                    Text(String(code)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                    Text(catalog?.entry(code: code)?.title ?? "RMI \(code)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { onSelect(nil) } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.bold))
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                            .background(Surface.card, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("RMI entfernen")
                }
                .padding(.leading, Spacing.m)
                .padding(.trailing, Spacing.xs)
                .frame(minHeight: TouchTarget.comfortable)
                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(code == nil ? "RMI suchen: Nummer oder Begriff" : "Anderen RMI suchen", text: $search)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
            }
            .inputBox()

            let results = Self.results(in: catalog, for: search)
            if !results.isEmpty {
                VStack(spacing: Spacing.xs) {
                    ForEach(results) { rmi in
                        Button {
                            onSelect(rmi.code)
                            search = ""
                            focused = false
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                                Text(String(rmi.code)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rmi.title).font(.headline).foregroundStyle(.primary)
                                    Text([rmi.category, rmi.triageHint].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: TouchTarget.comfortable)
                            .background(Surface.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(catalog == nil ? "Kein IVENA-Katalog geladen." : "Kein RMI gefunden.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Treffer: exakte Nummer zuerst, dann Nummern-Anfang, dann Text.
    static func results(in catalog: RMICatalog?, for search: String) -> [RMI] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, !text.isEmpty else { return [] }
        let found = catalog.search(text)
        let ranked = found.sorted { lhs, rhs in
            let left = (String(lhs.code) == text ? 0 : String(lhs.code).hasPrefix(text) ? 1 : 2, lhs.code)
            let right = (String(rhs.code) == text ? 0 : String(rhs.code).hasPrefix(text) ? 1 : 2, rhs.code)
            return left < right
        }
        return Array(ranked.prefix(maxResults))
    }
}

/// ABCD-Status: ein Knopf je Buchstabe; ein Tipp öffnet die vier Stufen (E50).
struct ABCDPicker: View {
    let status: ABCDStatus
    let onChange: (ABCDLetter, Int?) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 4), spacing: Spacing.s) {
            ForEach(ABCDLetter.allCases) { letter in
                Menu {
                    Section("\(letter.rawValue) – \(letter.title)") {
                        ForEach(ABCDLetter.levelRange, id: \.self) { level in
                            Button {
                                onChange(letter, level)
                            } label: {
                                if status[letter] == level {
                                    Label("\(letter.code(level))  \(letter.levels[level - 1])", systemImage: "checkmark")
                                } else {
                                    Text("\(letter.code(level))  \(letter.levels[level - 1])")
                                }
                            }
                        }
                    }
                    if status[letter] != nil {
                        Button("Angabe entfernen", role: .destructive) { onChange(letter, nil) }
                    }
                } label: {
                    tile(letter)
                }
                .accessibilityLabel(accessibilityText(letter))
            }
        }
    }

    @ViewBuilder
    private func tile(_ letter: ABCDLetter) -> some View {
        let level = status[letter]
        VStack(spacing: 2) {
            Text(level.map { letter.code($0) } ?? letter.rawValue)
                .font(.title2.weight(.heavy))
                .monospacedDigit()
            Text(level.map { letter.shortLevels[$0 - 1] } ?? "wählen")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(level == nil ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(level == nil ? Color.clear : Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Surface.separator, style: StrokeStyle(lineWidth: level == nil ? 2 : 0, dash: [6, 4]))
        }
    }

    private func accessibilityText(_ letter: ABCDLetter) -> String {
        if let level = status[letter] {
            return "\(letter.rawValue) \(letter.title): \(letter.code(level)), \(letter.levels[level - 1])"
        }
        return "\(letter.rawValue) \(letter.title): nicht angegeben"
    }
}
