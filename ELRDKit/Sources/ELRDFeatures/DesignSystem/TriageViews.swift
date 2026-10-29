import SwiftUI
import ELRDDomain

/// Abzeichen einer Sichtungskategorie, z. B. „SK 1“ auf rotem Grund.
public struct TriageBadge: View {
    public enum Size {
        case small, regular, large

        var font: Font {
            switch self {
            case .small: .caption.weight(.semibold)
            case .regular: .subheadline.weight(.bold)
            case .large: .title3.weight(.bold)
            }
        }

        var padding: EdgeInsets {
            switch self {
            case .small: EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
            case .regular: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            case .large: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            }
        }
    }

    let category: Sichtungskategorie
    let size: Size

    public init(_ category: Sichtungskategorie, size: Size = .regular) {
        self.category = category
        self.size = size
    }

    static func needsOutline(_ category: Sichtungskategorie) -> Bool {
        category == .unverletzt || category == .verstorben
    }

    public var body: some View {
        Text(category.shortName)
            .font(size.font)
            .monospacedDigit()
            .foregroundStyle(Color.onTriage(category))
            .padding(size.padding)
            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .overlay {
                // Sehr helle (unverletzt) und sehr dunkle (verstorben) Kennfarben verschwinden
                // sonst im hellen bzw. dunklen Modus – daher immer mit Rand.
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: Self.needsOutline(category) ? 1 : 0)
            }
            .accessibilityLabel(category.displayName)
    }
}

/// Zählerleiste je Sichtungskategorie, z. B. für Einsatzkopf und Übersicht.
public struct TriageSummaryView: View {
    let counts: [Sichtungskategorie: Int]
    let showsEmpty: Bool

    public init(counts: [Sichtungskategorie: Int], showsEmpty: Bool = false) {
        self.counts = counts
        self.showsEmpty = showsEmpty
    }

    /// Reihenfolge wie auf Sichtungskarten: SK 1–3, dann ungesichtet, unverletzt, verstorben.
    static let order: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet, .unverletzt, .verstorben]

    var visibleCategories: [Sichtungskategorie] {
        Self.order.filter { showsEmpty || (counts[$0] ?? 0) > 0 || [.sk1, .sk2, .sk3].contains($0) }
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) { items }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Spacing.s)], spacing: Spacing.s) { items }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var items: some View {
        ForEach(visibleCategories) { category in
            HStack(spacing: Spacing.xs) {
                TriageBadge(category, size: .small)
                Text("\(counts[category] ?? 0)")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(category.displayName): \(counts[category] ?? 0)")
        }
    }
}

#Preview("Sichtungskategorien") {
    VStack(alignment: .leading, spacing: Spacing.l) {
        HStack {
            ForEach(Sichtungskategorie.allCases) { TriageBadge($0) }
        }
        HStack {
            ForEach(Sichtungskategorie.allCases) { TriageBadge($0, size: .large) }
        }
        TriageSummaryView(counts: [.sk1: 1, .sk2: 2, .sk3: 3, .ungesichtet: 1])
    }
    .padding()
}
