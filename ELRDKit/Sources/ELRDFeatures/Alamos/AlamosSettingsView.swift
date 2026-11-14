import SwiftUI
import ELRDDomain

/// Einstellungen › Alamos FE2 (Schritt 140): Adresse des ELRD-Backends,
/// App-Schlüssel (Keychain), Abfragetakt, Vorgaben für die Übernahme.
struct AlamosSettingsView: View {
    @Environment(AlamosInbox.self) private var inbox: AlamosInbox?

    @State private var url = ""
    @State private var newKey = ""
    @State private var editsKey = false
    @State private var testState: TestState = .idle
    @State private var errorMessage: String?

    enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            if let inbox {
                content(inbox)
            } else {
                Text("Nicht verfügbar.")
            }
        }
        .navigationTitle("Alamos FE2")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            url = inbox?.settings.backendURL ?? ""
            editsKey = !(inbox?.hasAPIKey ?? false)
        }
        .onDisappear(perform: commitURL)
        .settingsError($errorMessage)
    }

    @ViewBuilder
    private func content(_ inbox: AlamosInbox) -> some View {
        let settings = inbox.settings
        Section {
            Toggle("Einsätze aus Alamos FE2 abrufen", isOn: binding(inbox, \.isEnabled))
                .frame(minHeight: TouchTarget.minimum)
        } footer: {
            Text("Die App fragt das ELRD-Backend regelmäßig ab, solange sie geöffnet ist. Neue Einsätze erscheinen oben in der Einsatzliste und lassen sich als Einsatz übernehmen.")
        }

        Section {
            TextField("https://elrd.example.de", text: $url)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(commitURL)
                .frame(minHeight: TouchTarget.minimum)
            if editsKey {
                SecureField("App-Schlüssel (elrd_…)", text: $newKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { saveKey(inbox) }
                    .frame(minHeight: TouchTarget.minimum)
                HStack {
                    Button("Schlüssel speichern") { saveKey(inbox) }
                        .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if inbox.hasAPIKey {
                        Spacer()
                        Button("Abbrechen", role: .cancel) {
                            newKey = ""
                            editsKey = false
                        }
                    }
                }
            } else {
                LabeledContent("App-Schlüssel") {
                    HStack(spacing: Spacing.m) {
                        Text("gespeichert ••••").foregroundStyle(.secondary)
                        Button("Ändern") { editsKey = true }
                        Button("Entfernen", role: .destructive) { removeKey(inbox) }
                    }
                }
                .frame(minHeight: TouchTarget.minimum)
            }
            Button {
                commitURL()
                Task { await test(inbox) }
            } label: {
                HStack {
                    Label("Verbindung testen", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if testState == .running { ProgressView() }
                }
            }
            .disabled(testState == .running || url.trimmingCharacters(in: .whitespaces).isEmpty)
            .frame(minHeight: TouchTarget.minimum)
            switch testState {
            case .success(let text):
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            default:
                EmptyView()
            }
        } header: {
            Text("ELRD-Backend")
        } footer: {
            Text("Adresse und App-Schlüssel bekommt ihr vom Betreiber des Backends (Verwaltungsseite › Organisation). Der Schlüssel liegt nur in der Keychain dieses Geräts. Im lokalen Netz geht auch http:// (bei einer IP-Adresse ohne Angabe automatisch), sonst nur https://.")
        }

        Section("Abfrage") {
            Picker("Abfragen alle", selection: binding(inbox, \.pollSeconds)) {
                ForEach(AlamosSettings.pollChoices, id: \.self) { seconds in
                    Text(seconds < 60 ? "\(seconds) Sekunden" : "\(seconds / 60) Minute\(seconds >= 120 ? "n" : "")").tag(seconds)
                }
            }
            Toggle("In FE2 geschlossene Einsätze zeigen", isOn: binding(inbox, \.showsClosed))
            Toggle("Testeinsätze zeigen", isOn: binding(inbox, \.showsTests))
            if let name = settings.organisationName {
                LabeledContent("Organisation", value: name)
            }
        }

        Section {
            Toggle("Alarmierte Fahrzeuge übernehmen", isOn: binding(inbox, \.importsVehicles))
            Toggle("Gemeldete Patienten anlegen", isOn: binding(inbox, \.importsPatients))
        } header: {
            Text("Beim Übernehmen")
        } footer: {
            Text("Vorgabe für „Als Einsatz übernehmen“; lässt sich dort je Einsatz ändern. Fahrzeuge werden über den Funkrufnamen in den Stammdaten gesucht, sonst als temporäre Einheit angelegt.")
        }

        Section("So wird FE2 angebunden") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("1. Im Alarmablauf einer eigenen FE2-Einheit „ELRD-Export“: **JSON-Plugin** (JSON in Alarmtext schreiben, Datenformat **V2**, Passwort leer).")
                Text("2. Direkt danach **MQTT-Plugin** mit Broker, Benutzer und Topic `elrd/<organisation>/alarm` vom Betreiber.")
                Text("3. Die Einheiten, deren Einsätze ELRD bekommen soll, lösen „ELRD-Export“ mit „Einheiten alarmieren“ aus.")
                Text("Anleitung und Testskript: Ordner `backend` und `tools/alamos` im ELRD-Projekt.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, Spacing.xs)
        }
    }

    // MARK: Aktionen

    private func binding<Value>(_ inbox: AlamosInbox, _ path: WritableKeyPath<AlamosSettings, Value>) -> Binding<Value> {
        Binding(
            get: { inbox.settings[keyPath: path] },
            set: { value in
                do { try inbox.updateSettings { $0[keyPath: path] = value } } catch { errorMessage = ErrorText.message(for: error) }
            }
        )
    }

    private func commitURL() {
        guard let inbox else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != inbox.settings.backendURL else { return }
        do { try inbox.updateSettings { $0.backendURL = trimmed } } catch { errorMessage = ErrorText.message(for: error) }
    }

    private func saveKey(_ inbox: AlamosInbox) {
        do {
            try inbox.setAPIKey(newKey)
            newKey = ""
            editsKey = false
            testState = .idle
            inbox.restart()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func removeKey(_ inbox: AlamosInbox) {
        do {
            try inbox.setAPIKey(nil)
            editsKey = true
            testState = .idle
            inbox.restart()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func test(_ inbox: AlamosInbox) async {
        testState = .running
        let key = newKey.trimmingCharacters(in: .whitespaces)
        do {
            let ping = try await inbox.testConnection(url: url, key: key.isEmpty ? nil : key)
            try? inbox.updateSettings { $0.organisationName = ping.organisationName }
            testState = .success("Verbunden mit „\(ping.organisationName)“ (Backend \(ping.version)).")
        } catch {
            testState = .failure(ErrorText.message(for: error))
        }
    }
}
