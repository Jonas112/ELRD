import SwiftUI
import ELRDDomain
import ELRDStore

/// Nachrichten (Glocke): oben schreiben, darunter neueste zuerst. Ungelesene sind
/// hervorgehoben; „Gelesen“ je Nachricht oder „Alle gelesen“.
struct MessagesView: View {
    let store: MissionStore

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWarning = false
    @State private var errorMessage: String?

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let messages = MissionMessage.newestFirst(store.state.messages)
        let unread = store.state.unreadMessageCount
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if canEdit { composer }
                    if messages.isEmpty {
                        Text("Noch keine Nachrichten. Sobald mehrere Geräte verbunden sind, erscheinen hier auch Nachrichten der anderen.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle()
                    }
                    LazyVStack(spacing: Spacing.s) {
                        ForEach(messages) { message in
                            MessageRow(message: message, canAcknowledge: store.isEnabled(.missionEditing)) {
                                perform(AcknowledgeMessages(message.id))
                            }
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .background(Surface.canvas)
            .navigationTitle(unread == 0 ? "Nachrichten" : "Nachrichten (\(unread) neu)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if unread > 0, store.isEnabled(.missionEditing) {
                        Button("Alle gelesen") { perform(AcknowledgeMessages()) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.bold)
                }
            }
            .alert("Nicht gespeichert", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            TextField("Nachricht an alle im Einsatz", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit(send)
                .inputBox()
            HStack(spacing: Spacing.s) {
                ChoiceChip("Information", isSelected: !isWarning, minHeight: TouchTarget.minimum + 4) { isWarning = false }
                ChoiceChip("Warnung", isSelected: isWarning, minHeight: TouchTarget.minimum + 4) { isWarning = true }
                Spacer(minLength: Spacing.s)
                Button(action: send) {
                    Label("Senden", systemImage: "paperplane.fill")
                        .font(.headline)
                        .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.white)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.comfortable)
                        .background(trimmed.isEmpty ? Surface.elevated : (isWarning ? Color.orange : ActionFill.primary),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
            }
        }
        .cardStyle()
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        if perform(SendMessage(trimmed, kind: isWarning ? .warning : .info)) {
            text = ""
            isWarning = false
        }
    }

    @discardableResult
    private func perform<Command: MissionCommand>(_ command: Command) -> Bool {
        do {
            _ = try store.perform(command)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Eine Nachricht: Absender, Zeit, Text; ungelesen mit Rand und „Gelesen“.
struct MessageRow: View {
    let message: MissionMessage
    let canAcknowledge: Bool
    let onAcknowledge: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(message.kind == .warning ? Color.orange : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Text(message.senderName).font(.headline)
                    Text(message.sentAt, format: .dateTime.hour().minute())
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if message.kind == .warning {
                        Text("Warnung").font(.caption.weight(.heavy)).foregroundStyle(.orange)
                    }
                }
                Text(message.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !message.isAcknowledged, canAcknowledge {
                Button("Gelesen", action: onAcknowledge)
                    .font(.headline)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(Spacing.m)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if !message.isAcknowledged {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(message.kind == .warning ? Color.orange : ActionFill.primary, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.isAcknowledged ? "" : "Ungelesen. ")\(message.kind.displayName) von \(message.senderName): \(message.text)")
    }

    private var symbol: String {
        switch message.kind {
        case .warning: "exclamationmark.triangle.fill"
        case .system: "gearshape.fill"
        case .info: "bubble.left.fill"
        }
    }
}
