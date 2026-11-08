import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ELRDDomain
import ELRDStore
import ELRDCloud

/// Abschnitt „Mit iCloud teilen“ in den Einsatzdaten.
///
/// Nicht geteilt: ein Knopf. Geteilt: Stand des Abgleichs, Einladung (QR-Code),
/// „Jetzt abgleichen“ und Trennen. Die lokale Kopie bleibt immer erhalten.
struct CloudShareSection: View {
    let store: MissionStore
    let cloud: CloudSyncCoordinator

    @State private var isWorking = false
    @State private var invite: CloudInvite?
    @State private var errorMessage: String?
    @State private var confirmsDisconnect = false

    var body: some View {
        let mission = store.missionID
        let link = cloud.link(for: mission)
        Section {
            if let link {
                statusRow(cloud.state(for: mission), pending: cloud.pendingCount(for: mission))
                if let url = link.shareURL {
                    Button { invite = CloudInvite(url: url, title: title) } label: {
                        Label("Einladung zeigen (QR-Code)", systemImage: "qrcode")
                            .frame(minHeight: TouchTarget.minimum)
                    }
                }
                Button {
                    Task { await cloud.syncNow(mission) }
                } label: {
                    Label("Jetzt abgleichen", systemImage: "arrow.clockwise.icloud")
                        .frame(minHeight: TouchTarget.minimum)
                }
                .disabled(cloud.state(for: mission).phase == .syncing || cloud.state(for: mission).phase == .revoked)
                Button(role: .destructive) { confirmsDisconnect = true } label: {
                    Label(link.isOwner ? "Teilen beenden" : "Einsatz verlassen", systemImage: "icloud.slash")
                        .frame(minHeight: TouchTarget.minimum)
                }
            } else {
                Button(action: share) {
                    HStack(spacing: Spacing.m) {
                        Label("Mit iCloud teilen", systemImage: "person.2.badge.plus")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                    .frame(minHeight: TouchTarget.minimum)
                }
                .disabled(isWorking)
            }
            if let problem = cloud.accountProblem {
                Label(problem, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Mehrere Geräte (iCloud)")
        } footer: {
            Text(footer(link))
        }
        .sheet(item: $invite) { invite in
            CloudInviteSheet(invite: invite)
        }
        .confirmationDialog(
            link?.isOwner == true ? "Teilen beenden?" : "Einsatz verlassen?",
            isPresented: $confirmsDisconnect,
            titleVisibility: .visible
        ) {
            Button(link?.isOwner == true ? "Teilen beenden" : "Verlassen", role: .destructive, action: disconnect)
        } message: {
            Text(link?.isOwner == true
                 ? "Alle anderen Geräte verlieren den Zugriff, die Kopie in deinem iCloud wird gelöscht. Auf allen Geräten bleiben die bisherigen Daten erhalten."
                 : "Dieses Gerät gleicht nicht mehr ab. Die Daten auf diesem Gerät bleiben erhalten.")
        }
    }

    private var title: String {
        let mission = store.state.mission
        return "\(mission.displayNumber()) \(mission.title)"
    }

    private func footer(_ link: CloudMissionLink?) -> String {
        guard let link else {
            return "Andere Geräte – auch mit anderer Apple-ID – treten per QR-Code bei und bearbeiten den Einsatz gemeinsam. Patientendaten sind Ende-zu-Ende verschlüsselt; Apple kann sie nicht lesen."
        }
        return link.isOwner
            ? "Du teilst diesen Einsatz. Der Speicher zählt in deinem iCloud."
            : "Du bist über eine Einladung beigetreten und kannst weitere Geräte mit demselben QR-Code einladen."
    }

    @ViewBuilder
    private func statusRow(_ state: CloudSyncState, pending: Int) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol(state.phase))
                .font(.title3)
                .foregroundStyle(color(state.phase))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(headline(state))
                    .font(.headline)
                if let message = state.message, state.phase != .idle {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if pending > 0 {
                    Text(pending == 1 ? "1 Änderung noch nicht übertragen" : "\(pending) Änderungen noch nicht übertragen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func headline(_ state: CloudSyncState) -> String {
        switch state.phase {
        case .idle:
            guard let last = state.lastSyncAt else { return "Verbunden" }
            return "Abgeglichen um \(last.formatted(date: .omitted, time: .shortened)) Uhr"
        case .syncing: return "Wird abgeglichen …"
        case .waiting:
            guard let retry = state.retryAt else { return "Wartet" }
            return "Neuer Versuch um \(retry.formatted(date: .omitted, time: .standard)) Uhr"
        case .failed: return "Abgleich angehalten"
        case .revoked: return "Nicht mehr geteilt"
        }
    }

    private func symbol(_ phase: CloudSyncState.Phase) -> String {
        switch phase {
        case .idle: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .waiting: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        case .revoked: "xmark.icloud"
        }
    }

    private func color(_ phase: CloudSyncState.Phase) -> Color {
        switch phase {
        case .idle: .green
        case .syncing: .accentColor
        case .waiting, .failed: .orange
        case .revoked: .secondary
        }
    }

    private func share() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let url = try await cloud.startSharing(store.missionID, title: title)
                cloud.requestSync(store.missionID)
                invite = CloudInvite(url: url, title: title)
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private func disconnect() {
        Task {
            do {
                try await cloud.disconnect(store.missionID)
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

/// Einladung zum Anzeigen.
struct CloudInvite: Identifiable {
    let url: URL
    let title: String
    var id: URL { url }
}

/// QR-Code und Link zum Weitergeben.
struct CloudInviteSheet: View {
    let invite: CloudInvite
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    Text(invite.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let image = QRCode.image(for: invite.url.absoluteString) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 360)
                            .padding(Spacing.l)
                            .background(.white, in: RoundedRectangle(cornerRadius: Radius.card))
                            .accessibilityLabel("QR-Code der Einladung")
                    }
                    Text("Mit der Kamera des anderen Geräts scannen. Dort öffnet sich ELRD und tritt dem Einsatz bei – auch mit einer anderen Apple-ID.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ShareLink(item: invite.url) {
                        Label("Link senden", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                    }
                    .buttonStyle(.bordered)
                    Text("Wer den Link hat, kann beitreten und bearbeiten. Nur an Einsatzkräfte weitergeben.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Einladung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.bold)
                }
            }
        }
    }
}

/// Einem geteilten Einsatz über einen Link beitreten (wenn nicht per Kamera geöffnet).
struct JoinCloudMissionSheet: View {
    let cloud: CloudSyncCoordinator
    let onJoined: (MissionID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.icloud.com/share/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.body.monospaced())
                    if UIPasteboard.general.hasURLs {
                        Button("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") {
                            if let url = UIPasteboard.general.url { link = url.absoluteString }
                        }
                    }
                } header: {
                    Text("Einladungslink")
                } footer: {
                    Text("Einfacher: den QR-Code mit der Kamera scannen. Dann öffnet sich ELRD von selbst.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button(action: join) {
                        HStack {
                            Text("Beitreten").font(.title3.weight(.bold))
                            Spacer()
                            if isWorking { ProgressView() }
                        }
                        .frame(minHeight: TouchTarget.comfortable)
                    }
                    .disabled(url == nil || isWorking)
                }
            }
            .navigationTitle("Einsatz beitreten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private var url: URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" else { return nil }
        return url
    }

    private func join() {
        guard let url else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let mission = try await cloud.join(url)
                dismiss()
                onJoined(mission)
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

/// QR-Code als Bild (CoreImage, keine Fremdbibliothek).
enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
