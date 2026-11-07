import SwiftUI
import StoreKit
import ELRDDomain
import ELRDEntitlements
import ELRDStammdaten

// MARK: - Vereinbarungen (Schritt 50)

/// Nutzungsbedingungen (aus ELRDRG, Stand Februar 2026) und Datenschutzerklärung
/// (Fassung 2, Stand November 2026: Kartenkacheln, Standort, Medien, Abo ergänzt).
enum Agreements {
    /// Bei inhaltlicher Änderung der Texte erhöhen – dann wird erneut nachgefragt.
    static let currentVersion = 2

    static var termsOfUse: String { text("Nutzungsbedingungen") }
    static var privacy: String { text("Datenschutz") }

    private static func text(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Rechtliches"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "Text nicht gefunden." }
        return text
    }

    static func isAccepted(_ settings: AppSettings) -> Bool {
        (settings.acceptedAgreementVersion ?? 0) >= currentVersion
    }
}

/// Beide Texte zum Lesen (Einstellungen → Vereinbarungen).
struct AgreementsView: View {
    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            SegmentedChoice(options: [(0, "Nutzungsbedingungen"), (1, "Datenschutz")], selection: $page)
                .padding(Spacing.l)
            ScrollView {
                Text(page == 0 ? Agreements.termsOfUse : Agreements.privacy)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(Spacing.xl)
                    .textSelection(.enabled)
            }
            if let settings = store?.settings, let at = settings.acceptedAgreementAt {
                Text("Angenommen am \(at.formatted(date: .numeric, time: .shortened)) (Fassung \(settings.acceptedAgreementVersion ?? 0))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(Spacing.m)
            }
        }
        .navigationTitle("Vereinbarungen")
    }
}

// MARK: - Einführung (Schritt 50)

/// Einführung beim ersten Start nach der Anmeldung: Willkommen, Vereinbarungen
/// annehmen (Pflicht), Region laden (optional), los geht's. Erscheint erneut, wenn
/// sich die Vereinbarungen ändern – dann nur dieser Schritt.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, agreements, region, done }

    let masterData: MasterDataEditor?
    let onFinish: () -> Void

    @Environment(AppSettingsStore.self) private var store: AppSettingsStore?
    @State private var step: Step = .welcome
    @State private var accepted = false
    @State private var showsRegions = false
    @State private var agreementPage = 0
    @State private var errorMessage: String?

    private var onlyAgreements: Bool { store?.settings.hasCompletedOnboarding == true }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .agreements: agreements
                case .region: region
                case .done: done
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.xl)
            footer
        }
        .background(Surface.canvas)
        .interactiveDismissDisabled()
        .onAppear { if onlyAgreements { step = .agreements } }
        .sheet(isPresented: $showsRegions) {
            if let masterData { RegionImportSheet(masterData: masterData) }
        }
        .settingsError($errorMessage)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Willkommen bei ELRD").font(.largeTitle.weight(.bold))
            Text("Die App unterstützt dich als Einsatzleiter Rettungsdienst bei Organisation und Dokumentation.")
                .font(.title3).foregroundStyle(.secondary)
            point("person.3.fill", "Patienten sichten und zuordnen", "Sichtung, Transportmittel, Zielklinik – mit großen Knöpfen, auch unter Stress.")
            point("map.fill", "Lagekarte", "Abschnitte, Markierungen und Zeichnungen auf der Karte.")
            point("book.pages.fill", "Tagebuch und Bericht", "Alles wird protokolliert; der PDF-Bericht entsteht auf Knopfdruck.")
            point("lock.fill", "Daten bleiben auf dem Gerät", "Ohne Konto bei Dritten, geschützt durch die iPad-Verschlüsselung.")
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.l) {
            Image(systemName: symbol).font(.title2).foregroundStyle(ActionFill.primary).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    private var agreements: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(onlyAgreements ? "Geänderte Vereinbarungen" : "Vereinbarungen").font(.largeTitle.weight(.bold))
            SegmentedChoice(options: [(0, "Nutzungsbedingungen"), (1, "Datenschutz")], selection: $agreementPage)
            ScrollView {
                Text(agreementPage == 0 ? Agreements.termsOfUse : Agreements.privacy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.l)
            }
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Toggle(isOn: $accepted) {
                Text("Ich habe die Bedingungen gelesen und akzeptiere diese.").font(.headline)
            }
            .toggleStyle(.switch)
            .frame(minHeight: TouchTarget.comfortable)
        }
    }

    private var region: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Fahrzeuge und Kliniken").font(.largeTitle.weight(.bold))
            Text("Lade die Stammdaten deiner Region – dann stehen Fahrzeuge und Kliniken sofort zur Auswahl. Später jederzeit unter Einstellungen → Stammdaten.")
                .font(.title3).foregroundStyle(.secondary)
            if let masterData {
                Button { showsRegions = true } label: {
                    Label(masterData.units.isEmpty ? "Region auswählen" : "\(masterData.units.count) Fahrzeuge, \(masterData.hospitals.count) Kliniken geladen – weitere Region",
                          systemImage: "arrow.down.circle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.large)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var done: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 80)).foregroundStyle(.green)
            Text("Alles bereit").font(.largeTitle.weight(.bold))
            Text("Lege einen Einsatz an oder schau dir zuerst die Einstellungen an.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            if step != .welcome, !onlyAgreements, step != .done {
                Button("Zurück") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    .font(.headline)
                    .frame(minWidth: 120, minHeight: TouchTarget.comfortable)
            }
            Spacer()
            Button(action: next) {
                Text(nextTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xl)
                    .frame(minHeight: TouchTarget.large)
                    .background(canContinue ? ActionFill.primary : Color.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canContinue)
        }
        .padding(Spacing.l)
        .background(Surface.card)
    }

    private var canContinue: Bool { step != .agreements || accepted }

    private var nextTitle: String {
        switch step {
        case .welcome: "Weiter"
        case .agreements: onlyAgreements ? "Annehmen" : "Annehmen und weiter"
        case .region: (masterData?.units.isEmpty ?? true) ? "Später" : "Weiter"
        case .done: "Los geht's"
        }
    }

    private func next() {
        switch step {
        case .welcome:
            step = .agreements
        case .agreements:
            do {
                try store?.update { settings in
                    settings.acceptedAgreementVersion = Agreements.currentVersion
                    settings.acceptedAgreementAt = Date()
                }
            } catch {
                errorMessage = ErrorText.message(for: error)
                return
            }
            if onlyAgreements { onFinish() } else { step = .region }
        case .region:
            step = .done
        case .done:
            do { try store?.update { $0.hasCompletedOnboarding = true } } catch { errorMessage = ErrorText.message(for: error) }
            onFinish()
        }
    }
}

// MARK: - Abo (Schritt 51)

struct SubscriptionView: View {
    @Environment(\.openURL) private var openURL
    /// `nil` bei Beispieldaten – dann gilt der Entwicklungsstand.
    @Environment(StoreKitEntitlements.self) private var subscriptions: StoreKitEntitlements?

    var body: some View {
        let current = subscriptions?.state ?? .development
        List {
            Section("Stand") {
                Label(current.summary(now: Date()), systemImage: current.hasFullAccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(current.hasFullAccess ? Color.green : Color.orange)
                    .frame(minHeight: TouchTarget.minimum)
            }
            Section {
                ForEach(Feature.allCases, id: \.self) { feature in
                    let always = EntitlementPolicy.standard.alwaysAvailable.contains(feature)
                    Label(feature.displayName, systemImage: always ? "checkmark" : "lock.open")
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("Im Abo enthalten")
            } footer: {
                Text("Ohne Abo bleiben deine Einsätze lesbar und als PDF exportierbar.")
            }
            if let subscriptions {
                Section("Kaufen") {
                    if subscriptions.products.isEmpty {
                        Text("Abo-Angebot wird geladen … (ohne Internet nicht verfügbar)").foregroundStyle(.secondary)
                    }
                    ForEach(subscriptions.products, id: \.id) { product in
                        Button {
                            Task { await subscriptions.purchase(product) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName).font(.headline)
                                    Text(product.description).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(product.displayPrice).font(.headline)
                            }
                            .frame(minHeight: TouchTarget.comfortable)
                        }
                        .disabled(subscriptions.isPurchasing)
                    }
                    Button("Käufe wiederherstellen") { Task { await subscriptions.restore() } }
                    Button("Abo verwalten") {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") { openURL(url) }
                    }
                }
                if let message = subscriptions.message {
                    Section { Text(message).foregroundStyle(.orange) }
                }
            }
        }
        .navigationTitle("Abo")
        .task { await subscriptions?.refresh() }
    }
}
