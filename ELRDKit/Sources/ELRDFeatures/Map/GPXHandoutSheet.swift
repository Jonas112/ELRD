import SwiftUI
import ELRDDomain

/// Schritt 120: GPX für Hundeteams per Link und QR-Code. Empfänger scannen mit dem
/// Handy, laden die Datei von iCloud und öffnen sie in Garmin Explore.
struct GPXHandoutSheet: View {
    let mission: MissionID
    let title: String
    /// Erzeugt den aktuellen Inhalt (bei „Neu freigeben“ mit dem neuesten Stand).
    let makeContents: () -> String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @State private var center = GPXShareCenter.shared
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var localFile: ExportedFile?

    private var publication: GPXPublication? {
        center.publications(for: mission).first { $0.fileName == GPXExport.fileName(title) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let publication {
                        published(publication)
                    } else {
                        intro
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        do { localFile = try GPXSharing.file(named: title, contents: makeContents()) } catch { errorMessage = ErrorText.message(for: error) }
                    } label: {
                        Label("Ohne Netz: Datei direkt senden (AirDrop)", systemImage: "square.and.arrow.up.on.square")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Für Hundeteams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
            .sheet(item: $localFile) { file in ActivityView(items: [file.url]) }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Link und QR-Code für Garmin-Geräte", systemImage: "qrcode")
                .font(.headline)
            Text("Die GPX-Datei (Einsatzort, Abschnitte, Formen, taktische Zeichen – keine Patientendaten) kommt in dein iCloud Drive. Wer den Link oder QR-Code hat, kann sie ohne ELRD und ohne Apple-Konto herunterladen.")
                .foregroundStyle(.secondary)
            Text(appSettings?.settings.deletesGPXSharesOnClose ?? true
                 ? "Bei Einsatzende wird die Freigabe automatisch gelöscht."
                 : "Automatisches Löschen bei Einsatzende ist in den Einstellungen ausgeschaltet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: publish) {
                HStack {
                    Label("Link erstellen", systemImage: "link.badge.plus").font(.title3.weight(.bold))
                    Spacer()
                    if isWorking { ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
            if isWorking {
                Text("Datei wird in iCloud hochgeladen …").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func published(_ publication: GPXPublication) -> some View {
        VStack(spacing: Spacing.l) {
            if let image = QRCode.image(for: publication.link.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .padding(Spacing.l)
                    .background(.white, in: RoundedRectangle(cornerRadius: Radius.card))
                    .accessibilityLabel("QR-Code zum Herunterladen der GPX-Datei")
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("1. QR-Code mit dem Handy scannen und die Datei laden.")
                Text("2. In der App „Garmin Explore“ öffnen und aufs Gerät übertragen – oder per Kabel in den Ordner „Garmin/GPX“ kopieren.")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(stamp(publication))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShareLink(item: publication.link) {
                Label("Link senden", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
            }
            .buttonStyle(.bordered)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) { republishButton; stopButton(publication) }
                VStack(spacing: Spacing.s) { republishButton; stopButton(publication) }
            }
        }
    }

    private var republishButton: some View {
        Button(action: publish) {
            HStack {
                Label("Neu freigeben", systemImage: "arrow.clockwise").font(.headline).lineLimit(1)
                if isWorking { ProgressView() }
            }
            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
        .accessibilityHint("Aktuellen Stand der Karte hochladen; neuer Link und QR-Code")
    }

    private func stopButton(_ publication: GPXPublication) -> some View {
        Button(role: .destructive) {
            Task { await center.remove(publication, mission: mission) }
        } label: {
            Label("Freigabe beenden", systemImage: "link.badge.minus")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
    }

    private func stamp(_ publication: GPXPublication) -> String {
        var text = "Stand \(publication.publishedAt.formatted(date: .omitted, time: .shortened)) Uhr"
        if let expires = publication.expiresAt {
            text += " · Link gültig bis \(expires.formatted(date: .numeric, time: .shortened))"
        }
        return text + ". Spätere Änderungen an der Karte: „Neu freigeben“."
    }

    private func publish() {
        isWorking = true
        errorMessage = nil
        let contents = makeContents()
        Task {
            defer { isWorking = false }
            do {
                _ = try await center.publish(contents, title: title, mission: mission)
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}
