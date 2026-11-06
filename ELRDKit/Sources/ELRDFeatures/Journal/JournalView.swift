import SwiftUI
import UIKit
import PhotosUI
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
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var isImporting = false
    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var player = VoicePlayer()

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
                            player: player,
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
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker(onImage: saveCameraPhoto, onFinish: { showsCamera = false })
                .ignoresSafeArea()
        }
        .onDisappear {
            player.stop()
            if recorder.isRecording { recorder.cancel() }
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
            mediaRow
            if let templates { templateChips(templates) }
        }
        .cardStyle()
    }

    // MARK: Fotos und Sprachnotizen

    /// Foto, Kamera, Sprachnotiz – der getippte Text wird zur Bildunterschrift.
    @ViewBuilder
    private var mediaRow: some View {
        if recorder.isRecording {
            recordingBar
        } else {
            HStack(spacing: Spacing.s) {
                PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 6, matching: .images) {
                    mediaLabel("Foto", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.plain)
                .disabled(isImporting)
                if CameraPicker.isAvailable {
                    Button { showsCamera = true } label: { mediaLabel("Kamera", systemImage: "camera.fill") }
                        .buttonStyle(.plain)
                }
                Button { Task { await recorder.start() } } label: { mediaLabel("Sprachnotiz", systemImage: "mic.fill") }
                    .buttonStyle(.plain)
                if isImporting { ProgressView().padding(.leading, Spacing.s) }
            }
            switch recorder.phase {
            case .denied:
                Text("Mikrofon nicht freigegeben (Einstellungen → ELRD → Mikrofon).")
                    .font(.subheadline).foregroundStyle(.orange)
            case .failed(let message):
                Text(message).font(.subheadline).foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
    }

    private func mediaLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: TouchTarget.comfortable)
            .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Während der Aufnahme: Zeit, Abbrechen, großes „Fertig“.
    private var recordingBar: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(Color.red).frame(width: 14, height: 14)
            if case .recording(let since) = recorder.phase {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Aufnahme \(DurationText.string(context.date.timeIntervalSince(since)))")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
            }
            Spacer(minLength: Spacing.s)
            Button("Abbrechen") { recorder.cancel() }
                .font(.headline)
                .frame(minHeight: TouchTarget.comfortable)
            Button(action: finishRecording) {
                Label("Fertig", systemImage: "stop.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: TouchTarget.comfortable)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.s)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aufnahme läuft")
    }

    private func finishRecording() {
        guard let recording = recorder.stop() else {
            errorMessage = "Die Aufnahme war zu kurz."
            return
        }
        do {
            let file = try attachments.save(recording.data, kind: .audio, createdAt: Date(), duration: recording.duration)
            addMedia([file])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer {
            isImporting = false
            pickedPhotos = []
        }
        var files: [FileAttachment] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                if let file = try PhotoImport.save(data, in: attachments) { files.append(file) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if files.isEmpty {
            errorMessage = errorMessage ?? "Die Fotos ließen sich nicht übernehmen."
        } else {
            addMedia(files)
        }
    }

    private func saveCameraPhoto(_ image: UIImage) {
        guard let jpeg = PhotoImport.jpeg(from: image) else {
            errorMessage = "Das Foto ließ sich nicht übernehmen."
            return
        }
        do {
            let file = try attachments.save(jpeg.data, kind: .photo, createdAt: Date(), pixelWidth: jpeg.width, pixelHeight: jpeg.height)
            addMedia([file])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Eintrag mit Anhängen; getippter Text wird Bildunterschrift.
    private func addMedia(_ files: [FileAttachment]) {
        do {
            _ = try store.perform(AddJournalMedia(attachments: files, text: trimmed, occurredAt: usesCustomTime ? occurredAt : nil))
            text = ""
            usesCustomTime = false
        } catch {
            errorMessage = error.localizedDescription
        }
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
    @ObservedObject var player: VoicePlayer
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
                let images = entry.attachments.filter { $0.kind == .photo || $0.kind == .drawing }
                if images.count == 1, let image = images.first {
                    Button { onShowImage(image) } label: {
                        AttachmentThumbnail(file: image, attachments: attachments)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bild öffnen")
                } else if images.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.s) {
                            ForEach(images) { image in
                                Button { onShowImage(image) } label: {
                                    AttachmentThumbnail(file: image, attachments: attachments, height: 120)
                                        .frame(width: 160)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Bild öffnen")
                            }
                        }
                    }
                }
                if entry.isMissionThumbnail {
                    Label("Vorschaubild des Einsatzes", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(entry.attachments.filter { $0.kind == .audio }) { audio in
                    Button { player.toggle(audio, in: attachments) } label: {
                        Label(
                            "Sprachnotiz \(DurationText.string(audio.duration ?? 0))",
                            systemImage: player.playingID == audio.id ? "stop.circle.fill" : "play.circle.fill"
                        )
                        .font(.headline)
                        .padding(.horizontal, Spacing.m)
                        .frame(minHeight: TouchTarget.comfortable)
                        .background(Surface.elevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.playingID == audio.id ? "Wiedergabe stoppen" : "Sprachnotiz abspielen, \(DurationText.string(audio.duration ?? 0))")
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
    var height: CGFloat? = nil
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
        .frame(maxWidth: 360, minHeight: height ?? 120, maxHeight: height ?? 200)
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
                    if entry.firstImage != nil {
                        let isThumbnail = store.state.journal.first { $0.id == entry.id }?.isMissionThumbnail ?? false
                        Toggle(isOn: Binding(
                            get: { isThumbnail },
                            set: { on in setThumbnail(on) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Vorschaubild des Einsatzes").font(.headline)
                                Text("Erscheint in der Einsatzliste und im Bericht.").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: TouchTarget.comfortable)
                    }
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

    private func setThumbnail(_ on: Bool) {
        do {
            try store.perform(SetMissionThumbnail(entryID: on ? entry.id : nil))
        } catch {
            errorMessage = error.localizedDescription
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
