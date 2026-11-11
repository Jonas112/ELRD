import SwiftUI
import ELRDDomain
import ELRDStore

/// Schritt 122: Mehrere Formen in eine GPX-Datei – Auswahl mit Haken, dann als
/// Datei teilen oder für Hundeteams per Link/QR-Code freigeben.
struct GPXExportSheet: View {
    let store: MissionStore

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<MapObjectID>
    @State private var includesMission = true
    @State private var includesSections = true
    @State private var name: String
    @State private var file: ExportedFile?
    @State private var showsHandout = false
    @State private var errorMessage: String?

    init(store: MissionStore) {
        self.store = store
        _selected = State(initialValue: Set(store.state.mapObjects.active.map(\.id)))
        let reason = store.state.mission.reason
        _name = State(initialValue: reason.isEmpty ? "Lagekarte" : "Lagekarte \(reason)")
    }

    private var objects: [MapObject] {
        store.state.mapObjects.active.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var placedSections: [MissionSection] {
        MissionSection.sorted(store.state.sections.active).filter { $0.coordinate != nil }
    }

    private var chosenCount: Int {
        selected.count + (includesMission && store.state.mission.coordinate != nil ? 1 : 0)
            + (includesSections ? placedSections.count : 0)
    }

    private var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Lagekarte" : trimmed
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name der Datei", text: $name)
                        .font(.headline)
                } header: {
                    Text("Datei")
                } footer: {
                    Text("Erscheint auf dem Garmin-Gerät als Name. Keine Patientendaten in der Datei.")
                }
                Section {
                    if store.state.mission.coordinate != nil {
                        Toggle(isOn: $includesMission) { Label("Einsatzort", systemImage: "flag.fill") }
                            .frame(minHeight: TouchTarget.minimum)
                    }
                    if !placedSections.isEmpty {
                        Toggle(isOn: $includesSections) {
                            Label("Abschnitte (\(placedSections.count))", systemImage: "square.stack.3d.up.fill")
                        }
                        .frame(minHeight: TouchTarget.minimum)
                    }
                } header: {
                    Text("Wegpunkte")
                }
                Section {
                    if objects.isEmpty {
                        Text("Noch keine Formen auf der Karte.").foregroundStyle(.secondary)
                    }
                    ForEach(objects) { object in
                        row(object)
                    }
                } header: {
                    HStack {
                        Text("Formen und Zeichen")
                        Spacer()
                        if !objects.isEmpty {
                            Button(selected.count == objects.count ? "Keine" : "Alle") {
                                selected = selected.count == objects.count ? [] : Set(objects.map(\.id))
                            }
                            .font(.subheadline.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("GPX-Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .sheet(item: $file) { file in ActivityView(items: [file.url]) }
            .sheet(isPresented: $showsHandout) {
                GPXHandoutSheet(mission: store.missionID, title: title, makeContents: document)
                    .largeSheet()
            }
        }
    }

    private func row(_ object: MapObject) -> some View {
        let isOn = selected.contains(object.id)
        return Button {
            if isOn { selected.remove(object.id) } else { selected.insert(object.id) }
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Group {
                    if let sign = object.tacticalSign {
                        Image(uiImage: TacticalSignRenderer.image(for: sign, height: 26))
                    } else {
                        Image(systemName: object.path.map { $0.kind == .polygon ? "pentagon.fill" : "arrow.up.right" }
                              ?? (object.shape.isDrawing ? "scribble" : object.shape.isCircle ? "circle.fill" : "rectangle.fill"))
                            .foregroundStyle(Color(object.color))
                    }
                }
                .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.displayName).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    Text(object.sizeText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: TouchTarget.comfortable)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var actions: some View {
        VStack(spacing: Spacing.s) {
            Text(chosenCount == 1 ? "1 Element ausgewählt" : "\(chosenCount) Elemente ausgewählt")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) { shareButton; handoutButton }
                VStack(spacing: Spacing.s) { shareButton; handoutButton }
            }
        }
        .padding(Spacing.l)
        .background(.regularMaterial)
    }

    private var shareButton: some View {
        Button {
            do { file = try GPXSharing.file(named: title, contents: document()) } catch { errorMessage = ErrorText.message(for: error) }
        } label: {
            Label("Als Datei teilen", systemImage: "square.and.arrow.up")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
        }
        .buttonStyle(.borderedProminent)
        .disabled(chosenCount == 0)
    }

    private var handoutButton: some View {
        Button { showsHandout = true } label: {
            Label("Für Hundeteams (QR)", systemImage: "qrcode")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
        }
        .buttonStyle(.bordered)
        .disabled(chosenCount == 0)
    }

    /// GPX aus der aktuellen Auswahl (zum Zeitpunkt des Teilens).
    private func document() -> String {
        let state = store.state
        return GPXExport.document(
            title: title,
            missionCoordinate: includesMission ? state.mission.coordinate : nil,
            sections: includesSections ? state.sections.active : [],
            objects: state.mapObjects.active.filter { selected.contains($0.id) },
            createdAt: Date()
        )
    }
}
