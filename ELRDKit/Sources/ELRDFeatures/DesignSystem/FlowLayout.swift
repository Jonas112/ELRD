import SwiftUI

/// Ordnet Elemente nebeneinander an und bricht in die nächste Zeile um,
/// wenn der Platz nicht reicht (z. B. Auswahl-Chips).
///
/// Ein Element, das allein breiter ist als der Platz (langer Textbaustein auf dem
/// iPhone), bekommt höchstens die volle Breite und bricht dann in sich um.
public struct FlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = Spacing.s) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Größe eines Elements, höchstens so breit wie der Platz.
    private func size(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth, maxWidth.isFinite else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    private func arrange(subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let itemSize = size(of: subviews[index], maxWidth: maxWidth)
            let needed = current.indices.isEmpty ? itemSize.width : current.width + spacing + itemSize.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? itemSize.width : current.width + spacing + itemSize.width
            current.height = max(current.height, itemSize.height)
            current.indices.append(index)
            current.sizes.append(itemSize)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
