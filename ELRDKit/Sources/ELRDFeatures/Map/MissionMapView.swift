import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereich „Karte“: Lagekarte mit Einsatzort, eigenem Standort, Maßstab und
/// wählbarer Kartengrundlage (Apple, OpenStreetMap, OpenTopoMap).
struct MissionMapView: View {
    let store: MissionStore

    @AppStorage(MapBaseLayer.storageKey) private var layer: MapBaseLayer = .apple
    @StateObject private var location = LocationAccess()
    @State private var focus: MapFocusRequest?
    @State private var showsLocationDenied = false
    /// Einsatzort wird auf die Kartenmitte (Fadenkreuz) gesetzt.
    @State private var placingMission = false
    @State private var center: GeoCoordinate?
    @State private var errorMessage: String?

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }

    var body: some View {
        let mission = store.state.mission
        let isPlacing = canEdit && (placingMission || mission.coordinate == nil)
        ZStack(alignment: .topTrailing) {
            MapCanvas(
                layer: layer,
                missionCoordinate: mission.coordinate,
                missionTitle: mission.location.isEmpty ? "Einsatzort" : mission.location,
                showsUserLocation: location.isAllowed,
                focus: focus,
                onCenterChange: { center = $0 }
            )

            if isPlacing {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.red)
                    .shadow(color: .white, radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: Spacing.s) {
                layerMenu
                missionControl(mission)
                MapControlButton(title: "Ich", systemImage: location.isAllowed ? "location.fill" : "location") {
                    locateMe()
                }
                .accessibilityLabel("Mein Standort")
            }
            .padding(Spacing.m)
        }
        .overlay(alignment: .bottom) {
            if isPlacing { placingBar(hasCoordinate: mission.coordinate != nil) }
        }
        .overlay(alignment: .bottomTrailing) {
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
        .alert("Standort nicht freigegeben", isPresented: $showsLocationDenied) {
            Button("Einstellungen") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Den eigenen Standort zeigt die Karte erst, wenn ELRD ihn verwenden darf (Einstellungen → ELRD → Standort).")
        }
        .onChange(of: location.permission) { _, permission in
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
        }
    }

    /// Einsatzort: hinspringen oder (neu) auf die Kartenmitte setzen.
    @ViewBuilder
    private func missionControl(_ mission: Mission) -> some View {
        if let coordinate = mission.coordinate, canEdit {
            Menu {
                Button { focus = MapFocusRequest(target: .coordinate(coordinate)) } label: {
                    Label("Zum Einsatzort", systemImage: "flag.fill")
                }
                Button { placingMission = true } label: {
                    Label("Einsatzort verschieben", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
            } label: {
                MapControlLabel(title: "Einsatzort", systemImage: "flag.fill")
            } primaryAction: {
                focus = MapFocusRequest(target: .coordinate(coordinate))
            }
            .accessibilityLabel("Zum Einsatzort")
        } else {
            MapControlButton(title: "Einsatzort", systemImage: "flag.fill") {
                if let coordinate = mission.coordinate { focus = MapFocusRequest(target: .coordinate(coordinate)) }
            }
            .disabled(mission.coordinate == nil)
        }
    }

    /// Leiste unten, solange der Einsatzort gesetzt wird.
    private func placingBar(hasCoordinate: Bool) -> some View {
        VStack(spacing: Spacing.s) {
            Text(hasCoordinate ? "Karte verschieben, bis das Kreuz auf dem Einsatzort liegt." : "Noch kein Einsatzort. Karte verschieben, bis das Kreuz darauf liegt.")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.s) {
                if hasCoordinate {
                    Button("Abbrechen") { placingMission = false }
                        .font(.headline)
                        .frame(minWidth: 120, minHeight: TouchTarget.comfortable)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .buttonStyle(.plain)
                }
                Button(action: placeMission) {
                    Label("Einsatzort hier", systemImage: "flag.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
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
        .frame(maxWidth: 520)
    }

    private func placeMission() {
        guard let center else { return }
        do {
            try store.perform(SetMissionCoordinate(center))
            placingMission = false
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func locateMe() {
        switch location.permission {
        case .allowed: focus = MapFocusRequest(target: .user)
        case .unknown: location.request()
        case .denied: showsLocationDenied = true
        }
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
