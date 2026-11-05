import SwiftUI
import ELRDDomain

/// Stelle am Körper: Region und – bei Extremitäten – Seite.
struct BodySpot: Hashable {
    let region: BodyRegion
    let side: BodySide?

    init(_ region: BodyRegion, _ side: BodySide? = nil) {
        self.region = region
        self.side = region.hasSide ? side : nil
    }

    /// „Unterschenkel rechts“, „Thorax“.
    var title: String {
        [region.displayName, side?.displayName].compactMap { $0 }.joined(separator: " ")
    }
}

/// Ein antippbares Körperteil der Grafik in Einheitskoordinaten (240 × 420).
///
/// Vorderansicht wie bei einem gegenüberstehenden Patienten: seine rechte
/// Seite liegt links in der Grafik (beschriftet mit „rechts“).
struct BodyPart: Identifiable {
    enum Form { case ellipse, rounded(CGFloat), spine }

    let spot: BodySpot
    /// Gezeichnete Fläche.
    let drawn: CGRect
    /// Größere Tippfläche, damit auch Arme und Hände leicht zu treffen sind.
    let hit: CGRect
    let form: Form

    var id: BodySpot { spot }

    static let canvas = CGSize(width: 240, height: 420)

    /// Alle Teile; die Tippflächen überlappen sich nicht.
    static let all: [BodyPart] = [
        BodyPart(spot: BodySpot(.kopf), drawn: CGRect(x: 74, y: 4, width: 52, height: 60), hit: CGRect(x: 60, y: 0, width: 80, height: 72), form: .ellipse),
        BodyPart(spot: BodySpot(.thorax), drawn: CGRect(x: 64, y: 80, width: 72, height: 90), hit: CGRect(x: 64, y: 72, width: 72, height: 100), form: .rounded(18)),
        BodyPart(spot: BodySpot(.abdomen), drawn: CGRect(x: 66, y: 174, width: 68, height: 66), hit: CGRect(x: 64, y: 172, width: 72, height: 70), form: .rounded(16)),
        BodyPart(spot: BodySpot(.arm, .rechts), drawn: CGRect(x: 32, y: 82, width: 22, height: 140), hit: CGRect(x: 8, y: 72, width: 56, height: 152), form: .rounded(11)),
        BodyPart(spot: BodySpot(.arm, .links), drawn: CGRect(x: 146, y: 82, width: 22, height: 140), hit: CGRect(x: 136, y: 72, width: 56, height: 152), form: .rounded(11)),
        BodyPart(spot: BodySpot(.hand, .rechts), drawn: CGRect(x: 30, y: 226, width: 26, height: 34), hit: CGRect(x: 8, y: 224, width: 48, height: 48), form: .ellipse),
        BodyPart(spot: BodySpot(.hand, .links), drawn: CGRect(x: 144, y: 226, width: 26, height: 34), hit: CGRect(x: 144, y: 224, width: 48, height: 48), form: .ellipse),
        BodyPart(spot: BodySpot(.oberschenkel, .rechts), drawn: CGRect(x: 67, y: 244, width: 31, height: 88), hit: CGRect(x: 56, y: 242, width: 44, height: 92), form: .rounded(14)),
        BodyPart(spot: BodySpot(.oberschenkel, .links), drawn: CGRect(x: 102, y: 244, width: 31, height: 88), hit: CGRect(x: 100, y: 242, width: 44, height: 92), form: .rounded(14)),
        BodyPart(spot: BodySpot(.unterschenkel, .rechts), drawn: CGRect(x: 69, y: 336, width: 27, height: 82), hit: CGRect(x: 56, y: 334, width: 44, height: 86), form: .rounded(13)),
        BodyPart(spot: BodySpot(.unterschenkel, .links), drawn: CGRect(x: 104, y: 336, width: 27, height: 82), hit: CGRect(x: 100, y: 334, width: 44, height: 86), form: .rounded(13)),
        // Wirbelsäule neben dem Rumpf, da sie in der Vorderansicht verdeckt wäre.
        BodyPart(spot: BodySpot(.wirbelsaeule), drawn: CGRect(x: 208, y: 74, width: 24, height: 168), hit: CGRect(x: 192, y: 64, width: 48, height: 196), form: .spine),
    ]

    /// Anzahl der Verletzungen je Teil. Eine Extremität ohne Seite zählt auf beiden Seiten.
    static func counts(for injuries: [Injury]) -> [BodySpot: Int] {
        var result: [BodySpot: Int] = [:]
        for injury in injuries {
            guard let region = injury.region else { continue }
            let spots = region.hasSide && injury.side == nil
                ? [BodySpot(region, .rechts), BodySpot(region, .links)]
                : [BodySpot(region, injury.side)]
            for spot in spots { result[spot, default: 0] += 1 }
        }
        return result
    }
}

/// Körpergrafik: Tipp auf ein Körperteil wählt Region und Seite.
struct BodyDiagramView: View {
    let selection: BodySpot?
    let counts: [BodySpot: Int]
    /// `nil`: nur Anzeige.
    let onSelect: ((BodySpot) -> Void)?
    /// Beschriftung „rechts/links/WS“ (in der kleinen Ansicht aus).
    var showsLabels = true

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / BodyPart.canvas.width, proxy.size.height / BodyPart.canvas.height)
            let size = CGSize(width: BodyPart.canvas.width * scale, height: BodyPart.canvas.height * scale)
            ZStack(alignment: .topLeading) {
                // Hals (nicht antippbar).
                RoundedRectangle(cornerRadius: 4 * scale)
                    .fill(Self.baseFill)
                    .frame(width: 20 * scale, height: 20 * scale)
                    .offset(x: 90 * scale, y: 60 * scale)
                ForEach(BodyPart.all) { part in
                    partView(part, scale: scale)
                }
                if showsLabels { labels(scale: scale) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(BodyPart.canvas.width / BodyPart.canvas.height, contentMode: .fit)
        .accessibilityElement(children: onSelect == nil ? .combine : .contain)
    }

    static let baseFill = Color(uiColor: .systemGray4)
    static let injuredFill = Color.orange

    @ViewBuilder
    private func partView(_ part: BodyPart, scale: CGFloat) -> some View {
        let count = counts[part.spot] ?? 0
        let isSelected = selection == part.spot
        let content = Color.clear
            .frame(width: part.hit.width * scale, height: part.hit.height * scale)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                shape(part, count: count, isSelected: isSelected, scale: scale)
                    .frame(width: part.drawn.width * scale, height: part.drawn.height * scale)
                    .offset(x: (part.drawn.minX - part.hit.minX) * scale, y: (part.drawn.minY - part.hit.minY) * scale)
            }
            .overlay {
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: max(11, 15 * scale), weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5 * scale)
                        .frame(minWidth: 22 * scale, minHeight: 22 * scale)
                        .background(.white, in: Capsule())
                        .offset(
                            x: (part.drawn.midX - part.hit.midX) * scale,
                            y: (part.drawn.midY - part.hit.midY) * scale
                        )
                }
            }
            .offset(x: part.hit.minX * scale, y: part.hit.minY * scale)

        if let onSelect {
            Button { onSelect(part.spot) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(part.spot.title)
                .accessibilityValue(count > 0 ? "\(count) Verletzungen" : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content.accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func shape(_ part: BodyPart, count: Int, isSelected: Bool, scale: CGFloat) -> some View {
        let fill = isSelected ? ActionFill.primary : count > 0 ? Self.injuredFill : Self.baseFill
        let stroke = isSelected ? Color.primary : Color.clear
        switch part.form {
        case .ellipse:
            Ellipse().fill(fill).overlay(Ellipse().strokeBorder(stroke, lineWidth: 3))
        case .rounded(let radius):
            RoundedRectangle(cornerRadius: radius * scale, style: .continuous)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: radius * scale, style: .continuous).strokeBorder(stroke, lineWidth: 3))
        case .spine:
            VStack(spacing: 3 * scale) {
                ForEach(0..<9, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4 * scale, style: .continuous).fill(fill)
                }
            }
            .padding(isSelected ? 3 : 0)
            .overlay(RoundedRectangle(cornerRadius: 8 * scale).strokeBorder(stroke, lineWidth: 3))
        }
    }

    private func labels(scale: CGFloat) -> some View {
        let font = Font.system(size: max(11, 13 * scale), weight: .bold)
        return ZStack(alignment: .topLeading) {
            Text("rechts").font(font).foregroundStyle(.secondary)
                .frame(width: 60 * scale)
                .offset(x: 2 * scale, y: 274 * scale)
            Text("links").font(font).foregroundStyle(.secondary)
                .frame(width: 60 * scale)
                .offset(x: 138 * scale, y: 274 * scale)
            Text("WS").font(font).foregroundStyle(.secondary)
                .frame(width: 48 * scale)
                .offset(x: 196 * scale, y: 246 * scale)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
