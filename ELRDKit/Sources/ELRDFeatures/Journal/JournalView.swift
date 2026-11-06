import SwiftUI
import UIKit
import ELRDDomain
import ELRDPersistence
import ELRDStore

/// Bereich „Tagebuch“: oben schnell eintragen (Text, Zeit, Textbausteine),
/// darunter alle Einträge, neueste zuerst. Kartenausschnitte erscheinen mit Bild.
struct JournalView: View {
    let store: MissionStore
    let templates: JournalTemplateEditor?

    @Environment(\.attachmentStore) private var attachments
    @State private var text = ""
    @State private var usesCustomTime = false
    @State private var occurredAt = Date()
    @State private var showsAllTemplates = false
    @State private var editing: JournalEntry?
    @State private var viewing: FileAttachment?
    @State private var errorMessage: String?
    @FocusState private var textFocused: Bool

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let entries = Array(JournalEntry.chronological(store.state.journal).reversed())
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tagebuch").font(.title2.weight(.bold))
                        Text(entries.count == 1 ? "1 Eintrag" : "\(entries.count) Einträge")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if canEdit { composer }
                if entries.isEmpty {
                    Text("Noch keine Einträge.").font(.title3).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                }
                LazyVStack(spacing: Spacing.s) {
                    ForEach(entries) { entry in
                        JournalEntryRow(
                            entry: entry,
                            canEdit: canEdit && entry.origin != .automatic,
                            attachments: attachments,
                            onEdit: { editing = entry },
                            onShowImage: { viewing = $0 }
                        )
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Surface.canvas)
        .sheet(item: $editing) { entry in
            JournalEntryEditor(store: store, entry: entry)
        }
        .sheet(item: $viewing) { file in
            JournalImageViewer(file: file, attachments: attachments)
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if AppLaunchOptions.current.demoScreen == .journalEntry, editing == nil {
                editing = entries.first { $0.origin == .manual }
            }
        }
    }

    // MARK: Eintragen

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            TextField("Was ist passiert?", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(2...6)
                .focused($textFocused)
                .inputBox()
            HStack(spacing: Spacing.s) {
                if usesCustomTime {
                    DatePicker("Zeitpunkt", selection: $occurredAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Button("Jetzt") { usesCustomTime = false }
                        .font(.headline)
                        .frame(minHeight: TouchTarget.minimum)
                } else {
                    Button {
                        occurredAt = Date()
                        usesCustomTime = true
                    } label: {
                        Label("Jetzt", systemImage: "clock")
                            .font(.headline)
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: TouchTarget.minimum)
                            .background(Surface.elevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zeitpunkt: jetzt. Tippen, um eine frühere Zeit zu wählen.")
                }
                Spacer(minLength: Spacing.s)
                Button(action: save) {
                    Label("Eintragen", systemImage: "square.and.pencil")
                        .font(.headline)
                        .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.white)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.comfortable)
                        .background(trimmed.isEmpty ? Surface.elevated : ActionFill.primary,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
            }
            if let templates { templateChips(templates) }
        }
        .cardStyle()
    }

    private func templateChips(_ editor: JournalTemplateEditor) -> some View {
        let all = editor.templates
        let shown = showsAllTemplates ? all : Array(all.prefix(6))
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Textbausteine").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: Spacing.s) {
                ForEach(shown) { template in
                    ChoiceChip(template.text, isSelected: false, minHeight: 48) {
                        use(template, in: editor)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            do { try editor.remove(template) } catch { errorMessage = error.localizedDescription }
                        } label: {
                            Label("Baustein löschen", systemImage: "trash")
                        }
                    }
                }
                if all.count > shown.count {
                    ChoiceChip("Alle \(all.count) …", isSelected: false, minHeight: 48) { showsAllTemplates = true }
                }
                if !trimmed.isEmpty, !editor.contains(trimmed) {
                    ChoiceChip("+ Als Baustein", isSelected: false, minHeight: 48) {
                        do { try editor.add(trimmed) } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
    }

    /// Baustein übernehmen: leeres Feld wird gefüllt, sonst angehängt – dann
    /// lässt sich noch ergänzen („Nachalarmierung angefordert: 2 RTW“).
    private func use(_ template: JournalTemplate, in editor: JournalTemplateEditor) {
        text = trimmed.isEmpty ? template.text : "\(trimmed)\n\(template.text)"
        editor.markUsed(template)
        textFocused = true
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        do {
            _ = try store.perform(AddJournalText(trimmed, occurredAt: usesCustomTime ? occurredAt : nil))
            text = ""
            usesCustomTime = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Eine Zeile im Tagebuch: Uhrzeit und Nummer links, Text, Herkunft und Bild.
struct JournalEntryRow: View {
    let entry: JournalEntry
    let canEdit: Bool
    let attachments: AttachmentFileStore
    let onEdit: () -> Void
    let onShowImage: (FileAttachment) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.occurredAt, format: .dateTime.hour().minute())
                    .font(.title3.weight(.bold).monospacedDigit())
                Text(entry.number.description)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                if !Calendar.current.isDateInToday(entry.occurredAt) {
                    Text(entry.occurredAt, format: .dateTime.day().month(.twoDigits))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.s) {
                if entry.origin != .manual {
                    Label(entry.origin.displayName, systemImage: entry.origin == .mapSnapshot ? "map" : "gearshape")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let image = entry.firstImage {
                    Button { onShowImage(image) } label: {
                        AttachmentThumbnail(file: image, attachments: attachments)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bild öffnen")
                }
            }
            if canEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.headline)
                        .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                        .background(Surface.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Eintrag \(entry.number) bearbeiten")
            }
        }
        .padding(Spacing.m)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Vorschaubild eines Anhangs (aus der Dateiablage, beim Erscheinen geladen).
struct AttachmentThumbnail: View {
    let file: FileAttachment
    let attachments: AttachmentFileStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Label("Bild fehlt auf diesem Gerät", systemImage: "photo")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 360, minHeight: 120, maxHeight: 200)
        .background(Surface.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: file.id) {
            image = attachments.data(for: file).flatMap(UIImage.init(data:))
        }
    }
}

/// Bild groß ansehen und drucken.
struct JournalImageViewer: View {
    let file: FileAttachment
    let attachments: AttachmentFileStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("Bild fehlt", systemImage: "photo", description: Text("Die Datei liegt nicht auf diesem Gerät."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.9))
            .navigationTitle(file.kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let image { MapPrinting.print(image, jobName: "ELRD \(file.kind.displayName)") }
                    } label: {
                        Label("Drucken", systemImage: "printer")
                    }
                    .disabled(image == nil)
                }
            }
        }
        .task(id: file.id) {
            image = attachments.data(for: file).flatMap(UIImage.init(data:))
        }
    }
}

/// Eintrag ändern oder löschen.
struct JournalEntryEditor: View {
    let store: MissionStore
    let entry: JournalEntry
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var occurredAt: Date
    @State private var confirmsDelete = false
    @State private var errorMessage: String?

    init(store: MissionStore, entry: JournalEntry) {
        self.store = store
        self.entry = entry
        _text = State(initialValue: entry.text)
        _occurredAt = State(initialValue: entry.occurredAt)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("Text").font(.headline).foregroundStyle(.secondary)
                    TextField("Eintrag", text: $text, axis: .vertical)
                        .font(.title3)
                        .lineLimit(3...10)
                        .inputBox()
                    Text("Zeitpunkt").font(.headline).foregroundStyle(.secondary)
                    DatePicker("Zeitpunkt", selection: $occurredAt, in: ...max(Date(), entry.occurredAt), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Text("Erfasst \(entry.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)). Änderungen stehen im Protokoll.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) { confirmsDelete = true } label: {
                        Label("Eintrag löschen", systemImage: "trash")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(Spacing.xl)
            }
            .background(Surface.canvas)
            .navigationTitle("Eintrag \(entry.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).fontWeight(.bold)
                }
            }
            .confirmationDialog("Eintrag \(entry.number) löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    do {
                        try store.perform(DeleteJournalEntry(entryID: entry.id))
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } message: {
                Text("Die Nummer bleibt vergeben; das Protokoll behält den Vorgang.")
            }
            .alert("Nicht gespeichert", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            try store.perform(EditJournalEntry(entryID: entry.id, text: text, occurredAt: occurredAt))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
