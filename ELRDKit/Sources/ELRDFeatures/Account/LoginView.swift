import SwiftUI
import ELRDAuth
import ELRDDomain

/// Anmeldung: Benutzer wählen, ggf. Passwort eingeben.
struct LoginView: View {
    let userService: UserService

    @State private var selectedID: UserID?
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool

    private var users: [UserAccount] { userService.directory.activeUsers }
    private var selectedUser: UserAccount? { selectedID.flatMap { userService.directory.user($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Wer arbeitet an diesem Gerät?")
                            .font(.title2.weight(.bold))
                        Text("Benutzer auswählen, um sich anzumelden.")
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.m)], spacing: Spacing.m) {
                        ForEach(users) { user in
                            UserTile(user: user, isSelected: user.id == selectedID) { select(user) }
                        }
                    }

                    if let user = selectedUser {
                        loginPanel(for: user)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(Surface.canvas)
            .navigationTitle("Anmelden")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func loginPanel(for user: UserAccount) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                UserAvatar(user: user, size: 40)
                VStack(alignment: .leading) {
                    Text(user.displayName).font(.headline)
                    RoleLabel(role: user.role)
                }
            }

            if user.hasPassword {
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .submitLabel(.go)
                    .onSubmit(login)
                    .padding(Spacing.m)
                    .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Button(action: login) {
                HStack {
                    if isLoggingIn { ProgressView().tint(.white) }
                    Text("Anmelden").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoggingIn || (user.hasPassword && password.isEmpty))
        }
        .frame(maxWidth: 480, alignment: .leading)
        .cardStyle()
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
                errorMessage = error.localizedDescription
                password = ""
                passwordFocused = user.hasPassword
            }
            isLoggingIn = false
        }
    }
}

/// Kachel eines Benutzers in der Anmeldung.
private struct UserTile: View {
    let user: UserAccount
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                UserAvatar(user: user)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(user.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !user.callsign.isEmpty {
                        Text(user.callsign)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    RoleLabel(role: user.role)
                }
                Spacer(minLength: 0)
                if !user.hasPassword {
                    Image(systemName: "lock.open")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Ohne Passwort")
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable * 1.4, alignment: .leading)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Anmeldung") {
    PreviewEnvironmentView(screen: .login)
}
