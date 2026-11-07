import SwiftUI
import ELRDAuth
import ELRDDomain

/// Wen die Anmeldung vorschlägt: die zuletzt angemeldete Person, sonst die erste.
enum LoginSuggestion {
    static func preferred(in users: [UserAccount]) -> UserAccount? {
        let signedInBefore = users.filter { $0.lastLoginAt != nil }
        if let last = signedInBefore.max(by: { $0.lastLoginAt! < $1.lastLoginAt! }) { return last }
        return users.first
    }
}

/// Anmeldung: zuletzt angemeldete Person ist vorausgewählt – meist nur Passwort und „Anmelden“.
struct LoginView: View {
    let userService: UserService

    @State private var selectedID: UserID?
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool

    private var users: [UserAccount] { userService.directory.activeUsers }
    private var selectedUser: UserAccount? {
        selectedID.flatMap { userService.directory.user($0) } ?? LoginSuggestion.preferred(in: users)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                VStack(spacing: Spacing.m) {
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Anmelden").font(.largeTitle.weight(.heavy))
                }
                .padding(.top, Spacing.xxl)

                if let user = selectedUser {
                    loginPanel(for: user)
                }

                let others = users.filter { $0.id != selectedUser?.id }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("Andere Person")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, Spacing.s)
                        VStack(spacing: 0) {
                            ForEach(Array(others.enumerated()), id: \.element.id) { index, user in
                                if index > 0 { Divider().padding(.leading, 88) }
                                UserRow(user: user) { select(user) }
                            }
                        }
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Surface.canvas)
        .onAppear { passwordFocused = selectedUser?.hasPassword ?? false }
    }

    @ViewBuilder
    private func loginPanel(for user: UserAccount) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(spacing: Spacing.l) {
                UserAvatar(user: user, size: 72)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(user.displayName).font(.title2.weight(.bold))
                    Text(detail(for: user)).foregroundStyle(.secondary)
                }
            }

            if user.hasPassword {
                SecureField("Passwort", text: $password)
                    .font(.title2)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .submitLabel(.go)
                    .onSubmit(login)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 64)
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: passwordFocused ? 2 : 0)
                    }
                    .accessibilityLabel("Passwort für \(user.displayName)")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Button(action: login) {
                HStack(spacing: Spacing.m) {
                    if isLoggingIn { ProgressView().tint(.white) }
                    Text("Anmelden").font(.title3.weight(.heavy))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLoggingIn || (user.hasPassword && password.isEmpty))
            .opacity(isLoggingIn || (user.hasPassword && password.isEmpty) ? 0.5 : 1)
        }
        .padding(Spacing.xxl)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func detail(for user: UserAccount) -> String {
        var parts: [String] = []
        if !user.callsign.isEmpty { parts.append(user.callsign) }
        parts.append(user.role.displayName)
        if !user.hasPassword { parts.append("ohne Passwort") }
        return parts.joined(separator: " · ")
    }

    private func select(_ user: UserAccount) {
        selectedID = user.id
        password = ""
        errorMessage = nil
        passwordFocused = user.hasPassword
    }

    private func login() {
        guard let user = selectedUser, !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        let entered = user.hasPassword ? password : nil
        Task {
            do {
                try await userService.login(user.id, password: entered)
            } catch {
                errorMessage = ErrorText.message(for: error)
                password = ""
                passwordFocused = user.hasPassword
            }
            isLoggingIn = false
        }
    }
}

/// Zeile „Andere Person“.
private struct UserRow: View {
    let user: UserAccount
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.l) {
                UserAvatar(user: user, size: 52)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(user.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.xl)
            .frame(minHeight: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Als diese Person anmelden")
    }

    private var subtitle: String {
        var parts: [String] = []
        if !user.callsign.isEmpty { parts.append(user.callsign) }
        parts.append(user.hasPassword ? user.role.displayName : "ohne Passwort")
        return parts.joined(separator: " · ")
    }
}

#Preview("Anmeldung") {
    PreviewEnvironmentView(screen: .login)
}
