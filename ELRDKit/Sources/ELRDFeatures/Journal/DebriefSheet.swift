import SwiftUI
import ELRDDomain
import ELRDStore

/// Nachbesprechung (Schritt 107): Kennzahlen und Meilensteine zum Nachlesen, dazu
/// Teilnehmende, „Was lief gut“, „Was verbessern“, Maßnahmen. Auch bei beendetem
/// Einsatz bearbeitbar; als Text teilbar und im Bericht.
struct DebriefSheet: View {
    let store: MissionStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MissionDebrief
    @State private var errorMessage: String?
    @State private var showsShare = false

    init(store: MissionStore) {
        self.store = store
        _draft = State(initialValue: store.state.mission.debrief ?? MissionDebrief())
    }

    private var canEdit: Bool { store.isEnabled(.missionEditing) }

    var body: some View {
        let state = store.state
        let metrics = MissionMetrics(mission: state.mission, patients: state.patients, journal: state.journal, now: Date())
        NavigationStack {
            Form {
                Section("Kennzahlen") {
                    row("Patienten", "\(metrics.patientCount)")
                    row("Erste Sichtung", offset(metrics.firstTriageAt, metrics))
                    row("Alle gesichtet", offset(metrics.allTriagedAt, metrics))
                    row("Erster Transport", offset(metrics.firstTransportAt, metrics))
                    row("Letzter Patient versorgt", offset(metrics.lastPatientGoneAt, metrics))
                    ForEach([Sichtungskategorie.sk1, .sk2, .sk3], id: \.self) { category in
                        if let wait = metrics.waits[category] {
                            row("Wartezeit \(category.shortName)", "Ø \(wait.averageMinutes) min · längste \(wait.maximumMinutes) min")
                        }
                    }
                }
                Section {
                    DisclosureGroup("Meilensteine (\(metrics.milestones.count))") {
                        ForEach(metrics.milestones) { milestone in
                            HStack(alignment: .firstTextBaseline) {
                                Text(milestone.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                                Text(milestone.title)
                                Spacer()
                                if let minutes = metrics.minutesFromStart(milestone.date), milestone.kind != .start {
                                    Text("+\(minutes) min").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                field("Teilnehmende", text: $draft.participants, prompt: "Wer war bei der Nachbesprechung dabei?")
                field("Was lief gut", text: $draft.wentWell, prompt: "z. B. schnelle Sichtung, klare Funkdisziplin")
                field("Was verbessern", text: $draft.toImprove, prompt: "z. B. Bereitstellungsraum zu spät eingerichtet")
                field("Maßnahmen / zuständig", text: $draft.actions, prompt: "eine je Zeile, z. B. „Checkliste ergänzen – Max Muster“")
                if let date = store.state.mission.debrief?.conductedAt {
                    Section { Text("Gespeichert \(date.formatted(date: .numeric, time: .shortened))").foregroundStyle(.secondary) }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .disabled(!canEdit)
            .navigationTitle("Nachbesprechung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { save(); showsShare = errorMessage == nil } label: {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { if save() { dismiss() } }
                        .fontWeight(.bold)
                        .disabled(!canEdit)
                }
            }
            .sheet(isPresented: $showsShare) {
                ShareTextSheet(
                    title: "Nachbesprechung",
                    text: MissionDebriefText.text(mission: store.state.mission, patients: store.state.patients, journal: store.state.journal, now: Date()),
                    subject: "Nachbesprechung Einsatz \(store.state.mission.displayNumber())",
                    footnote: "Ohne Patientennamen."
                )
                .largeSheet()
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
            .frame(minHeight: TouchTarget.minimum)
    }

    private func offset(_ date: Date?, _ metrics: MissionMetrics) -> String {
        guard let date, let minutes = metrics.minutesFromStart(date) else { return "–" }
        return "+\(minutes) min (\(date.formatted(date: .omitted, time: .shortened)))"
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        Section(title) {
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(3...10)
                .frame(minHeight: TouchTarget.comfortable, alignment: .topLeading)
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard canEdit else { return true }
        do {
            try store.perform(SetDebrief(draft))
            errorMessage = nil
            return true
        } catch {
            errorMessage = ErrorText.message(for: error)
            return false
        }
    }
}
