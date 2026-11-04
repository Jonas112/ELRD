import SwiftUI
import ELRDAuth

extension UserAccount {
    /// Initialen für den Avatar, z. B. „EB“; ohne Namen aus dem Funkrufnamen.
    var initials: String {
        let letters = [firstName, lastName].compactMap(\.first)
        if !letters.isEmpty { return String(letters).uppercased() }
        return String(callsign.prefix(2)).uppercased()
    }
}

/// Runder Avatar mit Initialen.
struct UserAvatar: View {
    let user: UserAccount
    var size: CGFloat = 48

    var body: some View {
        Text(user.initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(user.isAdmin ? ActionFill.primary : Color(uiColor: .systemGray)))
            .accessibilityHidden(true)
    }
}

/// Kennzeichnung der Rolle.
struct RoleLabel: View {
    let role: UserRole

    var body: some View {
        Label(role.displayName, systemImage: role == .admin ? "key.fill" : "person.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// Angemeldeter Benutzer für Menüs in Arbeitsbereichen.
public struct AccountMenuModel {
    public let displayName: String
    public let detail: String
    public let signOut: () -> Void

    public init(displayName: String, detail: String, signOut: @escaping () -> Void) {
        self.displayName = displayName
        self.detail = detail
        self.signOut = signOut
    }
}

extension AccountMenuModel {
    /// Initialen aus dem Anzeigenamen, z. B. „Erika Beispiel“ → „EB“.
    var initials: String {
        let letters = displayName.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// Kontomenü als runder Avatar (Symbolleiste, Lageleiste).
struct AccountAvatarMenu: View {
    let account: AccountMenuModel
    var size: CGFloat = TouchTarget.comfortable

    var body: some View {
        Menu {
            Section("\(account.displayName) · \(account.detail)") {
                Button(role: .destructive, action: account.signOut) {
                    Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Text(account.initials)
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(ActionFill.primary))
        }
        .accessibilityLabel("Konto: \(account.displayName)")
    }
}

/// Kontomenü (Name, Rolle, Abmelden).
struct AccountMenuButton: View {
    let account: AccountMenuModel

    var body: some View {
        Menu {
            Section("\(account.displayName) · \(account.detail)") {
                Button(role: .destructive, action: account.signOut) {
                    Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Label(account.displayName, systemImage: "person.crop.circle")
        }
        .accessibilityLabel("Konto: \(account.displayName)")
    }
}
