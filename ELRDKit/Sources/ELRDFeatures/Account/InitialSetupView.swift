import SwiftUI
import ELRDAuth

/// Eingaben der Ersteinrichtung mit Prüfung (ohne Oberfläche testbar).
struct InitialSetupForm: Equatable {
    var firstName = ""
    var lastName = ""
    var callsign = ""
    var password = ""
    var passwordRepeat = ""

    enum Problem: Equatable {
        case nameMissing
        case passwordTooShort
        case passwordsDiffer
    }

    var problems: [Problem] {
        var result: [Problem] = []
        let hasName = !trimmed(firstName).isEmpty || !trimmed(lastName).isEmpty
        if !hasName { result.append(.nameMissing) }
        if password.count < PasswordPolicy.minimumLength { result.append(.passwordTooShort) }
        if !passwordRepeat.isEmpty && password != passwordRepeat { result.append(.passwordsDiffer) }
        return result
    }

    var isValid: Bool { problems.isEmpty && password == passwordRepeat }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Erster Start: Administrator anlegen.
struct InitialSetupView: View {
    let userService: UserService

    @State private var form = InitialSetupForm()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    enum Field { case firstName, lastName, callsign, password, passwordRepeat }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            .accessibilityHidden(true)
                        Text("Willkommen bei ELRD")
                            .font(.title2.weight(.bold))
                        Text("Lege zuerst einen Administrator an. Er verwaltet später Benutzer, Stammdaten und Einstellungen. Weitere Einsatzleiter kannst du danach hinzufügen.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.s)
                }

                Section("Administrator") {
                    TextField("Vorname", text: $form.firstName)
                        .textContentType(.givenName)
                        .focused($focus, equals: .firstName)
                        .submitLabel(.next)
                        .onSubmit { focus = .lastName }
                    TextField("Nachname", text: $form.lastName)
                        .textContentType(.familyName)
                        .focused($focus, equals: .lastName)
                        .submitLabel(.next)
                        .onSubmit { focus = .callsign }
                    TextField("Funkrufname (optional), z. B. ELRD 1", text: $form.callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .callsign)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                }

                Section {
                    SecureField("Passwort", text: $form.password)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .passwordRepeat }
                    SecureField("Passwort wiederholen", text: $form.passwordRepeat)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .passwordRepeat)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("Passwort")
                } footer: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Mindestens \(PasswordPolicy.minimumLength) Zeichen. Das Passwort wird nur verschlüsselt (als Hash) gespeichert.")
                        if form.problems.contains(.passwordsDiffer) {
                            Label("Die Passwörter stimmen nicht überein.", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            if isSaving { ProgressView().tint(.white).padding(.trailing, Spacing.s) }
                            Text("Einrichten").font(.title3.weight(.heavy))
                            Spacer()
                        }
                        .foregroundStyle(form.isValid ? Color.white : Color.secondary)
                        .frame(minHeight: TouchTarget.large)
                    }
                    .disabled(!form.isValid || isSaving)
                    .listRowBackground(form.isValid ? ActionFill.primary : Surface.card)
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            // Fläche neben dem schmalen Formular im selben Grau wie das Formular.
            .background(Surface.canvas)
            .navigationTitle("Ersteinrichtung")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { focus = .firstName }
        }
    }

    private func save() {
        guard form.isValid, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let form = form
        Task {
            do {
                try await userService.createInitialAdmin(
                    firstName: form.firstName,
                    lastName: form.lastName,
                    callsign: form.callsign,
                    password: form.password
                )
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
            isSaving = false
        }
    }
}

#Preview("Ersteinrichtung") {
    PreviewEnvironmentView(screen: .setup)
}
