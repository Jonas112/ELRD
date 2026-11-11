import SwiftUI

// MARK: - Gemeinsame Bausteine (Schritt 127, E121)
//
// Wiederkehrende Elemente einmal gestaltet: Hauptknopf, Zweitknopf, Status-Marke
// und Leerzustand. Neue Oberflächen verwenden diese statt eigener Varianten.

/// Gefüllter Hauptknopf (eine Hauptaktion je Bildschirm).
public struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.primary.opacity(0.55))
            .background(
                isEnabled ? ActionFill.primary : Color.secondary.opacity(0.2),
                in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Getönter Zweitknopf (neben dem Hauptknopf).
public struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.accentColor : Color.primary.opacity(0.55))
            .background(
                (isEnabled ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.15)),
                in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Kleine farbige Marke für Zustände („angemeldet“, „Initial“, „Übung“).
public struct StatusChip: View {
    let text: String
    let systemImage: String?
    let color: Color

    public init(_ text: String, systemImage: String? = nil, color: Color = .accentColor) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(color)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xxs + 1)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}

/// Leerzustand mit Erklärung und – wenn sinnvoll – der nächsten Aktion.
public struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(systemImage: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.headline)
                        .padding(.horizontal, Spacing.xl)
                        .frame(minHeight: TouchTarget.comfortable)
                }
                .buttonStyle(PrimaryActionStyle())
                .padding(.top, Spacing.s)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
