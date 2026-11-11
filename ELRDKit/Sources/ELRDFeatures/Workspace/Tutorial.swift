import SwiftUI
import ELRDDomain
import ELRDStore

// MARK: - Lernpfad für neue Einsatzleiter (Schritt 139)

/// Ein Schritt des Lernpfads: was zu tun ist, wo, und woran die App erkennt,
/// dass er erledigt ist.
struct TutorialStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let explanation: String
    let section: WorkspaceSection
    let isDone: (MissionState, TutorialProgress) -> Bool

    static func == (lhs: TutorialStep, rhs: TutorialStep) -> Bool { lhs.id == rhs.id }

    static let all: [TutorialStep] = [
        TutorialStep(id: 1, title: "Patient anlegen",
                     explanation: "Oben „+ Patient“ oder unter Patienten eine Sichtungskategorie antippen – der Patient bekommt sofort eine Nummer.",
                     section: .patients) { state, _ in !state.patients.active.isEmpty },
        TutorialStep(id: 2, title: "Drei Patienten sichten",
                     explanation: "Lege zwei weitere Patienten an und gib jedem eine SK. Tipp: In der Liste lange drücken ändert die SK.",
                     section: .patients) { state, _ in state.patients.active.filter { $0.triage != .ungesichtet }.count >= 3 },
        TutorialStep(id: 3, title: "Einheit hinzufügen",
                     explanation: "Unter Einheiten „+ Einheit“: aus den Stammdaten wählen oder einen Funkrufnamen eintippen.",
                     section: .organisation) { state, _ in state.units.active.contains { !$0.isPlaceholder } },
        TutorialStep(id: 4, title: "Einheit einem Patienten zuordnen",
                     explanation: "Patient öffnen › Transport › „Einheit wählen“. Oder unter Einheiten den Patienten auf die Einheit ziehen.",
                     section: .patients) { state, _ in state.patients.active.contains { !$0.unitIDs.isEmpty } },
        TutorialStep(id: 5, title: "Zielklinik wählen",
                     explanation: "Im Patienten unter Transport die Zielklinik wählen und den Anmeldestatus setzen.",
                     section: .patients) { state, _ in state.patients.active.contains { $0.destination != nil } },
        TutorialStep(id: 6, title: "Transport starten",
                     explanation: "Mit Einheit und Klinik: „Transport starten“. Der Patient verschwindet aus „Warten“.",
                     section: .patients) { state, _ in state.patients.active.contains { $0.status == .inTransport || $0.outcome != nil } },
        TutorialStep(id: 7, title: "Tagebucheintrag schreiben",
                     explanation: "Unter Tagebuch „+ Eintrag“: kurz festhalten, was passiert ist – auch als Foto oder Sprachnotiz.",
                     section: .journal) { state, _ in state.journal.active.contains { $0.origin == .manual } },
        TutorialStep(id: 8, title: "Etwas auf der Karte markieren",
                     explanation: "Unter Karte „Zeichnen“: z. B. einen Gefahrenbereich oder ein taktisches Zeichen setzen.",
                     section: .map) { state, _ in !state.mapObjects.active.isEmpty },
        TutorialStep(id: 9, title: "Lagemeldung abgeben",
                     explanation: "Unter Lage „Lagemeldung“: die App schlägt den Text vor, du ergänzt und trägst ihn ins Tagebuch ein.",
                     section: .overview) { state, _ in state.lastSituationReportAt != nil },
        TutorialStep(id: 10, title: "Bericht ansehen",
                     explanation: "In der Seitenleiste „Bericht“: das PDF entsteht aus allem, was du erfasst hast.",
                     section: .overview) { _, progress in progress.openedReport },
    ]
}

/// Was die App sonst nicht in den Einsatzdaten sieht.
struct TutorialProgress: Equatable {
    var openedReport = false
}

/// Karte unten links im Lernpfad-Einsatz: aktueller Schritt, Fortschritt, „Hinführen“.
struct TutorialCoach: View {
    let state: MissionState
    let progress: TutorialProgress
    let onGo: (WorkspaceSection) -> Void

    @State private var isCollapsed = false

    private var steps: [TutorialStep] { TutorialStep.all }
    private var doneCount: Int { steps.filter { $0.isDone(state, progress) }.count }
    private var current: TutorialStep? { steps.first { !$0.isDone(state, progress) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "graduationcap.fill").foregroundStyle(.purple)
                Text("Lernpfad").font(.headline)
                Text("\(doneCount) von \(steps.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: Spacing.s)
                Button {
                    withAnimation(.snappy) { isCollapsed.toggle() }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                        .font(.headline)
                        .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Lernpfad aufklappen" : "Lernpfad einklappen")
            }
            ProgressView(value: Double(doneCount), total: Double(steps.count)).tint(.purple)
            if !isCollapsed {
                if let current {
                    Text("\(current.id). \(current.title)").font(.title3.weight(.bold))
                    Text(current.explanation).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { onGo(current.section) } label: {
                        Label("Hinführen: \(current.section.title)", systemImage: current.section.systemImage)
                            .font(.headline)
                            .padding(.horizontal, Spacing.l)
                            .frame(minHeight: TouchTarget.minimum)
                    }
                    .buttonStyle(SecondaryActionStyle())
                } else {
                    Label("Geschafft! Alle Schritte erledigt.", systemImage: "checkmark.seal.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.green)
                    Text("Unter Lage › Übungsleitung siehst du deine Punkte. Den Lernpfad kannst du jederzeit neu starten.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Color.purple.opacity(0.5), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .animation(.snappy, value: doneCount)
        .onChange(of: doneCount) { old, new in if new > old { Haptics.success() } }
        .accessibilityElement(children: .contain)
    }
}
