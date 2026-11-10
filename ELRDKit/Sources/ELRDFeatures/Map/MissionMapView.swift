import SwiftUI
import ELRDDomain
import ELRDStore

/// Was gerade über das Fadenkreuz in der Kartenmitte gesetzt wird.
enum MapPlacingTarget: Equatable {
    case mission
    case section(SectionID)
}

/// Bereich „Karte“: Lagekarte mit Einsatzort, Abschnitten, eigenem Standort,
/// Maßstab und wählbarer Kartengrundlage (Apple, OpenStreetMap, OpenTopoMap).
struct MissionMapView: View {
    let store: MissionStore

    @AppStorage(MapBaseLayer.storageKey) private var layer: MapBaseLayer = .apple
    @StateObject private var location = LocationAccess()
    /// Nach der Freigabe gleich den Einsatzort setzen (Schritt 61).
    @State private var placesMissionAfterPermission = false
    @State private var focus: MapFocusRequest?
    @State private var showsLocationDenied = false
    /// Gewähltes Ziel fürs Fadenkreuz; ohne Einsatzort ist es automatisch der Einsatzort.
    @State private var placing: MapPlacingTarget?
    @State private var center: GeoCoordinate?
    @State private var errorMessage: String?
    @State private var showsSectionList = false
    /// Liste links eingeklappt – mehr Platz für die Karte (Jonas). Nur Komfort je Gerät.
    @AppStorage("map.sidePanelCollapsed") private var sidePanelCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var proxy = MapCanvasProxy()
    @State private var editing: EditingMapObject?
    @Environment(\.attachmentStore) private var attachments
    /// Freihandzeichnen: Fläche über der Karte, Karte ruht solange.
    @State private var isDrawing = AppLaunchOptions.current.demoScreen == .mapDrawing
    @StateObject private var freehand = FreehandController()
    @State private var freehandTool = FreehandTool()
    @State private var confirmsDiscardDrawing = false
    /// Kurze Bestätigung oben (z. B. „Als Eintrag A-4 im Tagebuch“).
    @State private var notice: String?
    /// Schritt 111: angetipptes Foto.
    @State private var viewingPhoto: FileAttachment?
    /// Schritt 114: Auswahl taktischer Zeichen.
    @State private var showsSignPicker = AppLaunchOptions.current.demoScreen == .mapSigns
    /// Schritt 115: Polygon oder Pfeil, der gerade Punkt für Punkt gesetzt wird.
    @State private var pathDraft: MapPath? = AppLaunchOptions.current.demoScreen == .mapPath ? MissionMapView.demoPathDraft : nil

    /// Bildschirmfoto `mapPath`: Fläche mit drei gesetzten Ecken.
    static var demoPathDraft: MapPath {
        MapPath(kind: .polygon, points: [
            GeoCoordinate(latitude: 50.1018, longitude: 10.1772),
            GeoCoordinate(latitude: 50.1024, longitude: 10.1795),
            GeoCoordinate(latitude: 50.1011, longitude: 10.1801),
        ].compactMap { $0 })
    }

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }

    private func activePlacing(_ mission: Mission) -> MapPlacingTarget? {
        guard canEdit else { return nil }
        return placing ?? (mission.coordinate == nil ? .mission : nil)
    }

    var body: some View {
        GeometryReader { proxyGeometry in
            let isWide = proxyGeometry.size.width >= 900
            HStack(spacing: 0) {
                if isWide && !sidePanelCollapsed {
                    sidePanel
                        .transition(.move(edge: .leading))
                    Divider()
                }
                mapArea(showsSectionButton: !isWide)
                    .overlay(alignment: .leading) {
                        if isWide && sidePanelCollapsed { expandHandle }
                    }
            }
        }
        .sheet(isPresented: $showsSectionList) {
            NavigationStack {
                MapSectionList(
                    pins: MapSectionPin.pins(for: store.state),
                    objects: store.state.mapObjects.active,
                    canEdit: canEdit,
                    allowsDragging: false,
                    onSelect: { pin in showsSectionList = false; select(pin) },
                    onRemove: removeFromMap,
                    onSelectObject: { object in showsSectionList = false; selectObject(object) }
                )
                .navigationTitle("Auf der Karte")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showsSectionList = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $viewingPhoto) { file in
            JournalImageViewer(file: file, attachments: attachments)
        }
        .sheet(isPresented: $showsSignPicker) {
            TacticalSignPicker { preset in
                guard let center else { return }
                do {
                    _ = try store.perform(AddMapObject.sign(preset.sign, at: center))
                    show("\(preset.title) gesetzt – halten und ziehen verschiebt")
                } catch {
                    errorMessage = ErrorText.message(for: error)
                }
            }
            .largeSheet()
        }
        .sheet(item: $editing) { item in
            MapObjectEditor(store: store, objectID: item.id, mapCenter: center)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .alert("Standort nicht freigegeben", isPresented: $showsLocationDenied) {
            Button("Einstellungen") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Den eigenen Standort zeigt die Karte erst, wenn ELRD ihn verwenden darf (Einstellungen → ELRD → Standort).")
        }
        .onChange(of: location.permission) { _, permission in
            if placesMissionAfterPermission {
                placesMissionAfterPermission = false
                if permission == .allowed { placeMissionAtMyLocation() }
                return
            }
            if permission == .allowed, focus == nil { focus = MapFocusRequest(target: .user) }
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if center == nil {
                let start = MapCanvas.initialRegion(around: store.state.mission.coordinate).center
                center = GeoCoordinate(latitude: start.latitude, longitude: start.longitude)
            }
            if AppLaunchOptions.current.demoScreen == .mapTopo { layer = .openTopoMap }
            if let screen = AppLaunchOptions.current.demoScreen, [.map, .mapCollapsed].contains(screen) {
                sidePanelCollapsed = screen == .mapCollapsed
            }
            if AppLaunchOptions.current.demoScreen == .mapObject, editing == nil,
               let first = store.state.mapObjects.active.first {
                editing = EditingMapObject(id: first.id)
            }
        }
    }

    // MARK: Liste links (breit)

    /// Abschnitte und Markierungen; nach links wischen oder „‹‹“ klappt ein.
    private var sidePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Auf der Karte").font(.headline)
                Spacer()
                Button { setPanelCollapsed(true) } label: {
                    Image(systemName: "chevron.left.2")
                        .font(.headline)
                        .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                        .background(Surface.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Liste einklappen")
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            MapSectionList(
                pins: MapSectionPin.pins(for: store.state),
                objects: store.state.mapObjects.active,
                canEdit: canEdit,
                allowsDragging: true,
                onSelect: select,
                onRemove: removeFromMap,
                onSelectObject: selectObject
            )
        }
        .frame(width: 300)
        .background(Surface.canvas)
        // Kräftig nach links wischen klappt ein; senkrechtes Scrollen bleibt frei.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                let dx = value.translation.width
                if dx < -80, abs(dx) > abs(value.translation.height) * 2 { setPanelCollapsed(true) }
            }
        )
    }

    /// Schmaler Griff am linken Kartenrand: Tipp oder nach rechts wischen klappt aus.
    private var expandHandle: some View {
        Button { setPanelCollapsed(false) } label: {
            VStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.right.2").font(.headline)
                Image(systemName: "list.bullet").font(.headline)
            }
            .foregroundStyle(.primary)
            .frame(width: TouchTarget.minimum, height: 112)
            .background(.regularMaterial, in: UnevenRoundedRectangle(bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 4, x: 1, y: 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 16).onEnded { value in
                if value.translation.width > 40 { setPanelCollapsed(false) }
            }
        )
        .accessibilityLabel("Liste mit Abschnitten und Markierungen ausklappen")
    }

    /// Form direkt auf der Karte verschoben oder in der Größe geändert (Schritt 60).
    /// Verschieben an der Beschriftung bzw. am Zeichen; Linienzüge wandern als Ganzes.
    private func moveObject(_ id: MapObjectID, to coordinate: GeoCoordinate) {
        guard canEdit, let object = store.state.mapObjects.active.first(where: { $0.id == id }) else { return }
        if let path = object.path {
            let moved = path.moved(to: coordinate)
            if moved != path { _ = perform(EditMapObject(objectID: id, path: moved)) }
        } else {
            changeShape(id) { $0.moved(to: coordinate) }
        }
    }

    private func changeShape(_ id: MapObjectID, _ change: (MapShape) -> MapShape) {
        guard canEdit, let object = store.state.mapObjects.active.first(where: { $0.id == id }) else { return }
        let shape = change(object.shape)
        guard shape != object.shape else { return }
        _ = perform(EditMapObject(objectID: id, shape: shape))
    }

    private func setPanelCollapsed(_ collapsed: Bool) {
        if reduceMotion {
            sidePanelCollapsed = collapsed
        } else {
            withAnimation(.snappy) { sidePanelCollapsed = collapsed }
        }
    }

    private func mapArea(showsSectionButton: Bool) -> some View {
        let mission = store.state.mission
        let target = activePlacing(mission)
        return ZStack(alignment: .topTrailing) {
            MapCanvas(
                layer: layer,
                missionCoordinate: mission.coordinate,
                missionTitle: mission.location.isEmpty ? "Einsatzort" : mission.location,
                showsUserLocation: location.isAllowed,
                focus: focus,
                sections: MapSectionPin.pins(for: store.state),
                canEdit: canEdit,
                proxy: proxy,
                onCenterChange: { center = $0 },
                onMoveSection: { id, coordinate in perform(SetSectionCoordinate(sectionID: id, coordinate: coordinate)) },
                objects: store.state.mapObjects.active,
                onSelectObject: { editing = EditingMapObject(id: $0) },
                onMoveObject: { id, coordinate in moveObject(id, to: coordinate) },
                onResizeObject: { id, handle in changeShape(id) { $0.resized(handle: handle) } },
                attachments: attachments,
                onMoveMission: { coordinate in
                    if perform(SetMissionCoordinate(coordinate)) { show("Einsatzort verschoben") }
                },
                onRegionChanging: { if isDrawing { freehand.followMap(proxy) } },
                photos: MapPhotoPin.pins(for: store.state),
                onSelectPhoto: { viewingPhoto = $0.file },
                pathDraft: pathDraft,
                onTapMap: pathDraft == nil ? nil : { addPathPoint($0) }
            )
            .dropDestination(for: String.self) { items, point in
                guard canEdit,
                      case .section(let id)? = items.lazy.compactMap({ DragPayload(text: $0) }).first,
                      let coordinate = proxy.coordinate(at: point) else { return false }
                perform(SetSectionCoordinate(sectionID: id, coordinate: coordinate))
                return true
            }

            if isDrawing {
                FreehandCanvas(controller: freehand, tool: freehandTool)
                    // „Karte bewegen“: Berührungen gehen an die Karte, die Zeichnung folgt.
                    .onAppear { DispatchQueue.main.async { freehand.anchorIfNeeded(proxy) } }
                    .accessibilityLabel("Zeichenfläche über der Karte")
            }

            if target != nil || pathDraft != nil, !isDrawing {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.red)
                    .shadow(color: .white, radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if !isDrawing, pathDraft == nil { mapControls(mission, showsSectionButton: showsSectionButton) }
        }
        .overlay(alignment: .bottomLeading) {
            if !NetworkStatus.shared.isOnline, !isDrawing, activePlacing(mission) == nil {
                Label(
                    layer.tileTemplate == nil
                        ? "Offline – nur bereits geladene Kartenteile"
                        : "Offline – Karte aus dem Speicher",
                    systemImage: "wifi.slash"
                )
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(.regularMaterial, in: Capsule())
                .padding(Spacing.m)
                .padding(.bottom, Spacing.xl)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if isDrawing {
                FreehandToolbar(
                    tool: $freehandTool,
                    strokeCount: freehand.strokeCount,
                    onUndo: freehand.undo,
                    onCancel: cancelDrawing,
                    onDone: finishDrawing
                )
            } else if let pathDraft {
                pathBar(pathDraft)
            } else if let target {
                placingBar(for: target, mission: mission)
            }
        }
        .overlay(alignment: .top) {
            if let notice, !isDrawing {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(Color.green.opacity(0.9), in: Capsule())
                    .padding(.top, Spacing.m)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
            if let pathDraft, !isDrawing {
                Label(pathDraft.kind == .polygon
                      ? "Ecken antippen oder Fadenkreuz + „Punkt“ · mindestens 3"
                      : "Punkte antippen, der letzte wird zur Spitze · mindestens 2",
                      systemImage: pathDraft.kind == .polygon ? "pentagon" : "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, Spacing.m)
                    .allowsHitTesting(false)
            }
            if isDrawing {
                Label("Ein Finger oder Stift zeichnet · zwei Finger verschieben und zoomen", systemImage: "scribble")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, Spacing.m)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog("Zeichnung verwerfen?", isPresented: $confirmsDiscardDrawing, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { endDrawing() }
            Button("Weiterzeichnen", role: .cancel) {}
        }
        .overlay(alignment: .bottomTrailing) {
            attributionLabel
        }
    }

    private func mapControls(_ mission: Mission, showsSectionButton: Bool) -> some View {
            VStack(spacing: Spacing.s) {
                layerMenu
                missionControl(mission)
                MapControlButton(title: "Ich", systemImage: location.isAllowed ? "location.fill" : "location") {
                    locateMe()
                }
                .accessibilityLabel("Mein Standort")
                if canEdit { drawMenu }
                snapshotMenu
                if showsSectionButton {
                    MapControlButton(title: "Liste", systemImage: "list.bullet") {
                        showsSectionList = true
                    }
                    .accessibilityLabel("Abschnitte und Markierungen")
                }
            }
            .padding(Spacing.m)
    }

    @ViewBuilder
    private var attributionLabel: some View {
            if let attribution = layer.attribution {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.trailing, Spacing.s)
                    .padding(.bottom, 32)
                    .accessibilityLabel("Quelle: \(attribution)")
            }
    }

    // MARK: Kartenausschnitt

    /// Ausschnitt ins Tagebuch oder drucken (ELRDRG: Karte drucken).
    private var snapshotMenu: some View {
        Menu {
            if canEdit {
                Button(action: saveSnapshotToJournal) {
                    Label("Ins Tagebuch", systemImage: "book.pages")
                }
            }
            Button(action: printSnapshot) {
                Label("Drucken", systemImage: "printer")
            }
        } label: {
            MapControlLabel(title: "Ausschnitt", systemImage: "camera.viewfinder")
        }
        .accessibilityLabel("Kartenausschnitt ins Tagebuch oder drucken")
    }

    private func saveSnapshotToJournal() {
        guard let image = proxy.snapshot(), let jpeg = image.jpegData(compressionQuality: 0.85) else {
            errorMessage = "Der Kartenausschnitt ließ sich nicht erzeugen."
            return
        }
        do {
            let file = try attachments.save(
                jpeg,
                kind: .photo,
                createdAt: Date(),
                pixelWidth: Int(image.size.width * image.scale),
                pixelHeight: Int(image.size.height * image.scale)
            )
            let entry = try store.perform(AddMapSnapshot(image: file))
            show("Als Eintrag \(entry.number) im Tagebuch")
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func printSnapshot() {
        guard let image = proxy.snapshot() else {
            errorMessage = "Der Kartenausschnitt ließ sich nicht erzeugen."
            return
        }
        let mission = store.state.mission
        MapPrinting.print(image, jobName: "Lagekarte \(mission.reason.isEmpty ? "Einsatz" : mission.reason)")
    }

    private func show(_ message: String) {
        withAnimation { notice = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if notice == message { withAnimation { notice = nil } }
        }
    }

    // MARK: Freihand

    private func startDrawing() {
        placing = nil
        proxy.resetHeading()
        proxy.setRotationEnabled(false)
        freehand.reset()
        freehandTool = FreehandTool()
        isDrawing = true
    }

    private func cancelDrawing() {
        if freehand.strokeCount > 0 { confirmsDiscardDrawing = true } else { endDrawing() }
    }

    private func endDrawing() {
        freehand.clear()
        freehand.reset()
        proxy.setRotationEnabled(true)
        isDrawing = false
    }

    /// Bild speichern und als Zeichnung über ihrem Kartenrechteck anlegen.
    private func finishDrawing() {
        guard let export = freehand.export(proxy) else { return }
        let topLeft = export.topLeft
        let bottomRight = export.bottomRight
        do {
            let file = try attachments.save(
                export.png,
                kind: .drawing,
                createdAt: Date(),
                pixelWidth: Int(export.pixelSize.width),
                pixelHeight: Int(export.pixelSize.height)
            )
            let object = try store.perform(AddMapObject(shape: .drawing(bounds: GeoBounds(enclosing: topLeft, bottomRight), image: file)))
            endDrawing()
            editing = EditingMapObject(id: object.id)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    /// Einsatzort: hinspringen oder ändern. Ein Tipp öffnet die Auswahl – das
    /// Ändern war hinter langem Drücken versteckt (Jonas). Außerdem lässt sich die
    /// rote Fahne direkt auf der Karte ziehen.
    @ViewBuilder
    private func missionControl(_ mission: Mission) -> some View {
        if let coordinate = mission.coordinate, canEdit {
            Menu {
                Button { focus = MapFocusRequest(target: .coordinate(coordinate)) } label: {
                    Label("Zum Einsatzort", systemImage: "flag.fill")
                }
                Button {
                    focus = MapFocusRequest(target: .coordinate(coordinate))
                    placing = .mission
                } label: {
                    Label("Einsatzort ändern (Kreuz)", systemImage: "scope")
                }
                Button { placeMissionAtMyLocation() } label: {
                    Label("Einsatzort = mein Standort", systemImage: "location.fill")
                }
            } label: {
                MapControlLabel(title: "Einsatzort", systemImage: "flag.fill")
            }
            .accessibilityLabel("Einsatzort: hinspringen oder ändern")
        } else {
            MapControlButton(title: "Einsatzort", systemImage: "flag.fill") {
                if let coordinate = mission.coordinate { focus = MapFocusRequest(target: .coordinate(coordinate)) }
            }
            .disabled(mission.coordinate == nil)
        }
    }

    private func targetName(_ target: MapPlacingTarget) -> String {
        switch target {
        case .mission: "Einsatzort"
        case .section(let id): "„\(store.state.activeSections.first { $0.id == id }?.name ?? "Abschnitt")“"
        }
    }

    /// Leiste unten, solange etwas über das Fadenkreuz gesetzt wird.
    private func placingBar(for target: MapPlacingTarget, mission: Mission) -> some View {
        let name = targetName(target)
        let canCancel = placing != nil && !(target == .mission && mission.coordinate == nil)
        let hint = target == .mission && mission.coordinate == nil
            ? "Noch kein Einsatzort. Karte verschieben, bis das Kreuz darauf liegt."
            : "Karte verschieben, bis das Kreuz auf \(target == .mission ? "dem Einsatzort" : name) liegt."
        return VStack(spacing: Spacing.s) {
            Text(hint)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.s) {
                if canCancel {
                    Button("Abbrechen") { placing = nil }
                        .font(.headline)
                        .frame(minWidth: 120, minHeight: TouchTarget.comfortable)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .buttonStyle(.plain)
                }
                if target == .mission {
                    // Schritt 61: Einsatzort = eigener Standort (beim Eintreffen).
                    Button(action: placeMissionAtMyLocation) {
                        Label(location.isLocating ? "Orte …" : "Mein Standort", systemImage: "location.fill")
                            .font(.headline)
                            .lineLimit(1)
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: TouchTarget.comfortable)
                            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(location.isLocating)
                    .accessibilityLabel("Einsatzort auf meinen Standort setzen")
                }
                Button { place(target) } label: {
                    Label("\(name) hier", systemImage: target == .mission ? "flag.fill" : "square.stack.3d.up.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.comfortable)
                        .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(center == nil)
            }
        }
        .padding(Spacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, 44)
        .frame(maxWidth: 560)
    }

    private func place(_ target: MapPlacingTarget) {
        guard let center else { return }
        let done: Bool
        switch target {
        case .mission: done = perform(SetMissionCoordinate(center))
        case .section(let id): done = perform(SetSectionCoordinate(sectionID: id, coordinate: center))
        }
        if done { placing = nil }
    }

    /// Tipp in der Liste: platzierte Abschnitte anspringen, sonst Fadenkreuz.
    private func select(_ pin: MapSectionPin) {
        if let coordinate = pin.coordinate {
            focus = MapFocusRequest(target: .coordinate(coordinate))
        } else if canEdit {
            placing = .section(pin.id)
        }
    }

    private func removeFromMap(_ pin: MapSectionPin) {
        perform(SetSectionCoordinate(sectionID: pin.id, coordinate: nil))
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

    /// Kreis oder Rechteck in der Kartenmitte anlegen und gleich bearbeiten.
    private var drawMenu: some View {
        Menu {
            Button { addObject(center.map(MapObjectPalette.newCircle(at:))) } label: {
                Label("Kreis", systemImage: "circle")
            }
            Button { addObject(center.flatMap(MapObjectPalette.newRectangle(at:))) } label: {
                Label("Rechteck", systemImage: "rectangle")
            }
            Button { startPath(.polygon) } label: {
                Label("Fläche (Polygon)", systemImage: "pentagon")
            }
            Button { startPath(.arrow) } label: {
                Label("Pfeil", systemImage: "arrow.up.right")
            }
            Button(action: startDrawing) {
                Label("Freihand", systemImage: "scribble")
            }
            Divider()
            Button { showsSignPicker = true } label: {
                Label("Taktisches Zeichen …", systemImage: "square.on.circle")
            }
        } label: {
            MapControlLabel(title: "Zeichnen", systemImage: "pencil.and.outline")
        }
        .accessibilityLabel("Kreis, Rechteck, Fläche, Pfeil, freihand oder taktisches Zeichen")
    }

    // MARK: Polygon und Pfeil (Schritt 115)

    private func pathButtons(_ draft: MapPath, compact: Bool) -> some View {
        HStack(spacing: Spacing.s) {
            Button(role: .cancel) { pathDraft = nil } label: {
                Label("Abbrechen", systemImage: "xmark").labelStyle(PathLabelStyle(compact: compact))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Abbrechen")
            Button {
                guard var updated = pathDraft, !updated.points.isEmpty else { return }
                updated.points.removeLast()
                pathDraft = updated
            } label: {
                Label("Zurück", systemImage: "arrow.uturn.backward").labelStyle(PathLabelStyle(compact: compact))
            }
            .buttonStyle(.bordered)
            .disabled(draft.points.isEmpty)
            .accessibilityLabel("Letzten Punkt entfernen")
            Button {
                if let center { addPathPoint(center) }
            } label: {
                Label("Punkt", systemImage: "plus.circle.fill").labelStyle(PathLabelStyle(compact: compact))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Punkt in der Kartenmitte setzen")
            Button {
                finishPath()
            } label: {
                Text(draft.isValid ? "Fertig (\(draft.points.count))" : "\(draft.points.count) von \(draft.minimumPoints)")
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!draft.isValid)
        }
    }

    private func startPath(_ kind: MapPath.Kind) {
        placing = nil
        pathDraft = MapPath(kind: kind, points: [])
    }

    private func addPathPoint(_ coordinate: GeoCoordinate) {
        guard var draft = pathDraft else { return }
        draft.points.append(coordinate)
        pathDraft = draft
    }

    private func finishPath() {
        guard let draft = pathDraft, let command = AddMapObject.withPath(draft) else { return }
        do {
            let object = try store.perform(command)
            pathDraft = nil
            editing = EditingMapObject(id: object.id)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    /// Große Knöpfe unten: Punkt in der Kartenmitte, rückgängig, abbrechen, fertig.
    private func pathBar(_ draft: MapPath) -> some View {
        // iPhone: Symbole statt Text, damit die Knöpfe nicht umbrechen.
        ViewThatFits(in: .horizontal) {
            pathButtons(draft, compact: false)
            pathButtons(draft, compact: true)
        }
        .font(.headline)
        .controlSize(.large)
        .frame(minHeight: TouchTarget.comfortable)
        .padding(Spacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.bottom, Spacing.xl)
        .padding(.horizontal, Spacing.m)
    }

    private func addObject(_ shape: MapShape?) {
        guard let shape else { return }
        do {
            let object = try store.perform(AddMapObject(shape: shape))
            editing = EditingMapObject(id: object.id)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func selectObject(_ object: MapObject) {
        focus = MapFocusRequest(target: .coordinate(object.shape.center))
        editing = EditingMapObject(id: object.id)
    }

    private var layerMenu: some View {
        Menu {
            Picker("Kartengrundlage", selection: $layer) {
                ForEach(MapBaseLayer.allCases) { candidate in
                    Label(candidate.title, systemImage: candidate.systemImage).tag(candidate)
                }
            }
        } label: {
            MapControlLabel(title: layer.shortTitle, systemImage: "square.3.layers.3d")
        }
        .accessibilityLabel("Kartengrundlage: \(layer.title)")
    }

    /// Einsatzort auf den eigenen Standort setzen; fragt bei Bedarf nach der Freigabe.
    private func placeMissionAtMyLocation() {
        switch location.permission {
        case .denied:
            showsLocationDenied = true
        case .unknown:
            placesMissionAfterPermission = true
            location.request()
        case .allowed:
            Task {
                guard let coordinate = await location.currentCoordinate() else {
                    errorMessage = "Standort gerade nicht bestimmbar (z. B. in Gebäuden). Bitte Karte verschieben und „Einsatzort hier“ tippen."
                    return
                }
                if perform(SetMissionCoordinate(coordinate)) {
                    placing = nil
                    focus = MapFocusRequest(target: .coordinate(coordinate))
                }
            }
        }
    }

    private func locateMe() {
        switch location.permission {
        case .allowed: focus = MapFocusRequest(target: .user)
        case .unknown: location.request()
        case .denied: showsLocationDenied = true
        }
    }
}

/// Liste der Abschnitte neben bzw. über der Karte. Tipp: anspringen oder setzen;
/// auf großen iPads lassen sich Abschnitte direkt auf die Karte ziehen.
struct MapSectionList: View {
    let pins: [MapSectionPin]
    let objects: [MapObject]
    let canEdit: Bool
    let allowsDragging: Bool
    let onSelect: (MapSectionPin) -> Void
    let onRemove: (MapSectionPin) -> Void
    let onSelectObject: (MapObject) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Abschnitte").font(.title3.weight(.bold))
                if pins.isEmpty {
                    Text("Noch keine Abschnitte. Im Bereich „Einheiten“ anlegen.")
                        .foregroundStyle(.secondary)
                } else if canEdit {
                    Text(allowsDragging ? "Auf die Karte ziehen oder antippen." : "Antippen: anspringen oder setzen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(pins) { pin in
                    row(pin)
                }

                Text("Markierungen").font(.title3.weight(.bold)).padding(.top, Spacing.m)
                if objects.isEmpty {
                    Text(canEdit ? "Noch keine. Über „Zeichnen“ einen Kreis oder ein Rechteck anlegen." : "Keine Markierungen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(objects) { object in
                    objectRow(object)
                }
            }
            .padding(Spacing.l)
        }
    }

    private func objectRow(_ object: MapObject) -> some View {
        Button { onSelectObject(object) } label: {
            HStack(spacing: Spacing.m) {
                Group {
                    if let sign = object.tacticalSign {
                        Image(uiImage: TacticalSignRenderer.image(for: sign, height: 26))
                    } else {
                        Image(systemName: object.path.map { $0.kind == .polygon ? "pentagon.fill" : "arrow.up.right" }
                              ?? (object.shape.isDrawing ? "scribble" : object.shape.isCircle ? "circle.fill" : "rectangle.fill"))
                            .font(.title3)
                            .foregroundStyle(Color(object.color))
                    }
                }
                .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.displayName).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    Text(object.sizeText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 60)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Zeigt die Markierung und öffnet sie zum Bearbeiten.")
    }

    private func row(_ pin: MapSectionPin) -> some View {
        Button { onSelect(pin) } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: pin.coordinate == nil ? "mappin.slash" : "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(pin.coordinate == nil ? Color.secondary : Color.blue)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xs) {
                        Text(pin.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        if pin.isInitial {
                            Text("Initial")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ActionFill.primary, in: Capsule())
                        }
                    }
                    Text(pin.coordinate == nil ? "nicht auf der Karte" : (pin.summary.isEmpty ? "keine Einheiten" : pin.summary))
                        .font(.subheadline)
                        .foregroundStyle(pin.coordinate == nil ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 60)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canEdit, pin.coordinate != nil {
                Button(role: .destructive) { onRemove(pin) } label: {
                    Label("Von der Karte nehmen", systemImage: "mappin.slash")
                }
            }
        }
        .organisationDraggable(allowsDragging && canEdit ? .section(pin.id) : nil) {
            Label(pin.name, systemImage: "square.stack.3d.up.fill")
                .font(.headline)
                .padding(Spacing.m)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityHint(pin.coordinate == nil ? "Setzt den Abschnitt über das Fadenkreuz." : "Zeigt den Abschnitt auf der Karte.")
    }
}

/// Runder Kartenknopf mit Symbol und kurzer Beschriftung (auch nachts gut zu treffen).
struct MapControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MapControlLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

struct MapControlLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage).font(.title3.weight(.semibold))
            Text(title).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .frame(width: 68, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}

/// Knöpfe der Punktleiste: auf schmalen Geräten nur Symbol (Schritt 117).
private struct PathLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
                .frame(minWidth: 28)
        } else {
            HStack(spacing: 6) {
                configuration.icon
                configuration.title
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}
