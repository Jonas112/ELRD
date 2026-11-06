import SwiftUI
import ELRDDomain
import ELRDStore

/// Kennung für `sheet(item:)`.
struct EditingMapObject: Identifiable, Equatable {
    let id: MapObjectID
}

/// Kreis oder Rechteck bearbeiten. Jede Auswahl gilt sofort – die Karte dahinter
/// zeigt das Ergebnis (Blatt halbhoch). Größe und Farbe stehen oben, weil man
/// sie direkt nach dem Zeichnen braucht.
struct MapObjectEditor: View {
    let store: MissionStore
    let objectID: MapObjectID
    /// Aktuelle Kartenmitte (für „Hierher verschieben“).
    let mapCenter: GeoCoordinate?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var confirmsDelete = false
    @State private var errorMessage: String?

    private var object: MapObject? {
        store.state.mapObjects.active.first { $0.id == objectID }
    }

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }

    var body: some View {
        NavigationStack {
            Group {
                if let object {
                    form(object)
                } else {
                    ContentUnavailableView("Gelöscht", systemImage: "trash", description: Text("Diese Markierung gibt es nicht mehr."))
                }
            }
            .background(Surface.canvas)
            .navigationTitle(object?.shape.summary.components(separatedBy: ",").first ?? "Markierung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { commitText(); dismiss() }.fontWeight(.bold)
                }
            }
        }
        .onAppear {
            title = object?.title ?? ""
            note = object?.note ?? ""
        }
        .onDisappear(perform: commitText)
        .confirmationDialog("Markierung löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if perform(DeleteMapObject(objectID: objectID)) { dismiss() }
            }
        } message: {
            Text("Sie verschwindet von der Karte; das Protokoll behält den Eintrag.")
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func form(_ object: MapObject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                sizeSection(object)

                Text("Farbe").font(.headline).foregroundStyle(.secondary)
                HStack(spacing: Spacing.s) {
                    ForEach(MapObjectPalette.colors.indices, id: \.self) { index in
                        let entry = MapObjectPalette.colors[index]
                        Button {
                            perform(EditMapObject(objectID: objectID, color: entry.color))
                        } label: {
                            Circle()
                                .fill(Color(entry.color))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if object.color == entry.color {
                                        Image(systemName: "checkmark").font(.headline.weight(.heavy))
                                            .foregroundStyle(Color(entry.color.contrastingTextColor))
                                    }
                                }
                                .frame(minWidth: TouchTarget.comfortable, minHeight: TouchTarget.comfortable)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.name)
                        .accessibilityAddTraits(object.color == entry.color ? .isSelected : [])
                    }
                }
                .disabled(!canEdit)

                Text("Bezeichnung").font(.headline).foregroundStyle(.secondary)
                TextField("z. B. Gefahrenbereich", text: $title)
                    .font(.title3)
                    .submitLabel(.done)
                    .onSubmit(commitText)
                    .inputBox()
                    .disabled(!canEdit)
                FlowLayout(spacing: Spacing.s) {
                    ForEach(MapObjectPalette.titles, id: \.self) { suggestion in
                        ChoiceChip(suggestion, isSelected: object.title == suggestion, minHeight: 48) {
                            title = suggestion
                            commitText()
                        }
                    }
                }
                .disabled(!canEdit)

                HStack(spacing: Spacing.s) {
                    Button {
                        if let mapCenter { perform(EditMapObject(objectID: objectID, shape: object.shape.moved(to: mapCenter))) }
                    } label: {
                        Label("In die Kartenmitte", systemImage: "scope")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(mapCenter == nil)
                    Button(role: .destructive) { confirmsDelete = true } label: {
                        Label("Löschen", systemImage: "trash")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .disabled(!canEdit)

                Text("Notiz").font(.headline).foregroundStyle(.secondary)
                TextField("optional", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .inputBox()
                    .disabled(!canEdit)
            }
            .padding(Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func sizeSection(_ object: MapObject) -> some View {
        HStack {
            Text("Größe").font(.headline).foregroundStyle(.secondary)
            Spacer()
            Text(object.shape.sizeText).font(.headline.monospacedDigit())
        }
        FlowLayout(spacing: Spacing.s) {
            switch object.shape {
            case let .circle(center, radius):
                ForEach(MapObjectPalette.radii, id: \.self) { candidate in
                    ChoiceChip(MapShape.metersText(candidate), isSelected: radius == candidate, minHeight: 48) {
                        perform(EditMapObject(objectID: objectID, shape: .circle(center: center, radiusMeters: candidate)))
                    }
                }
            case let .rectangle(bounds):
                ForEach(MapObjectPalette.rectangleSizes.indices, id: \.self) { index in
                    let size = MapObjectPalette.rectangleSizes[index]
                    ChoiceChip("\(Int(size.width)) × \(Int(size.height)) m",
                               isSelected: abs(bounds.widthMeters - size.width) < 1 && abs(bounds.heightMeters - size.height) < 1,
                               minHeight: 48) {
                        if let resized = GeoBounds.around(bounds.center, widthMeters: size.width, heightMeters: size.height) {
                            perform(EditMapObject(objectID: objectID, shape: .rectangle(bounds: resized)))
                        }
                    }
                }
            case .drawing:
                EmptyView()
            }
        }
        .disabled(!canEdit)
        HStack(spacing: Spacing.s) {
            stepButton("Kleiner", systemImage: "minus", factor: 0.8, object: object)
            stepButton("Größer", systemImage: "plus", factor: 1.25, object: object)
        }
        .disabled(!canEdit)
    }

    private func stepButton(_ label: String, systemImage: String, factor: Double, object: MapObject) -> some View {
        Button {
            perform(EditMapObject(objectID: objectID, shape: MapObjectPalette.scaled(object.shape, by: factor)))
        } label: {
            Label(label, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Bezeichnung und Notiz übernehmen (nur wenn geändert).
    private func commitText() {
        guard canEdit, let object else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != object.title || note != object.note else { return }
        perform(EditMapObject(objectID: objectID, title: trimmed, note: note))
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
