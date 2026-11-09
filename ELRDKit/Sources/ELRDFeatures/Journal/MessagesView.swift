import SwiftUI
import ELRDDomain
import ELRDStore

/// Benachrichtigungen (Glocke): neue offene Punkte (Schritt 105) und Nachrichten.
/// Oben schreiben, darunter neueste zuerst. Ungelesene sind hervorgehoben;
/// „Gelesen“ je Nachricht oder „Alle gelesen“.
struct MessagesView: View {
    let store: MissionStore
    /// Zu einem offenen Punkt springen.
    var onOpen: (OpenItem.Target) -> Void = { _ in }

    @Environment(OpenItemNotifier.self) private var notifier: OpenItemNotifier?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWarning = false
    @State private var errorMessage: String?

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let messages = MissionMessage.newestFirst(store.state.messages)
        let unread = store.state.unreadMessageCount
        let records = notifier?.records(for: store.missionID) ?? []
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if !records.isEmpty { openItemRecords(records) }
                    Text("Nachrichten").font(.title3.weight(.bold))
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
            .navigationTitle("Benachrichtigungen")
            .onDisappear { notifier?.markAllRead(store.missionID) }
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

    /// Neue offene Punkte auf diesem Gerät, neueste zuerst; Tipp führt hin.
    private func openItemRecords(_ records: [OpenItemRecord]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Neue offene Punkte").font(.title3.weight(.bold))
                Spacer()
                if records.contains(where: { !$0.isRead }) {
                    Button("Alle gelesen") { notifier?.markAllRead(store.missionID) }
                        .font(.subheadline.weight(.semibold))
                }
            }
            ForEach(records.prefix(30)) { record in
                Button {
                    onOpen(record.item.target)
                } label: {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Image(systemName: record.isRead ? "bell" : "bell.badge.fill")
                            .font(.title3)
                            .foregroundStyle(record.isRead ? Color.secondary : Color.orange)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.item.title)
                                .font(record.isRead ? .body : .body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Text("\(record.date.formatted(date: .omitted, time: .shortened)) · \(record.item.kind.settingsTitle)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(record.item.actionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .padding(Spacing.m)
                    .frame(minHeight: TouchTarget.comfortable)
                    .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.orange, lineWidth: record.isRead ? 0 : 2))
                }
                .buttonStyle(.plain)
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
                .draftSync($text, field: .message, mission: store.missionID)
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
                .keyboardShortcut(.return, modifiers: .command)
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
            errorMessage = ErrorText.message(for: error)
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
