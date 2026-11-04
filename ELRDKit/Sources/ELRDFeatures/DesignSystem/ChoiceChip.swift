import SwiftUI

/// Großer Auswahlknopf (Stichwort, Einsatzart …). Ausgewählt: Akzentrand und getönte Fläche.
public struct ChoiceChip: View {
    let title: String
    let isSelected: Bool
    let minHeight: CGFloat
    let fillsWidth: Bool
    let action: () -> Void

    public init(
        _ title: String,
        isSelected: Bool,
        minHeight: CGFloat = TouchTarget.comfortable,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.minHeight = minHeight
        self.fillsWidth = fillsWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(isSelected ? .heavy : .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, Spacing.l)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: minHeight)
                .background(
                    isSelected ? ActionFill.selected : Surface.card,
                    in: RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
