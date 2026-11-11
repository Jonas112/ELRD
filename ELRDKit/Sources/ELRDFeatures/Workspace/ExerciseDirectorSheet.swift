import SwiftUI
import ELRDDomain
import ELRDStore

/// Übungsleiter-Modus (Schritt 138): Einlagen planen und einspielen, Punkte sehen.
/// Am besten auf dem Gerät der Übungsleitung im geteilten Einsatz (Rechte „Voll“).
struct ExerciseDirectorSheet: View {
    let store: MissionStore

    @Environment(\.dismiss) private var dismiss
    @State private var editing: ExerciseInject?
    @State private var errorMessage: String?

    private var injects: [ExerciseInject] { store.state.mission.exerciseInjects ?? [] }
    private var canEdit: Bool { !store.state.mission.isClosed }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            NavigationStack {
                List {
                    scoreSection(now: context.date)
                    Section {
                        if injects.isEmpty {
                            Text("Noch keine Einlagen. Unten aus den Vorlagen wählen oder eine eigene Meldung anlegen.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(injects) { inject in
                            row(inject, now: context.date)
                                .swipeActions {
                                    if !inject.isReleased, canEdit {
                                        Button(role: .destructive) { perform(RemoveExerciseInject(inject.id)) } label: { Label("Entfernen", systemImage: "trash") }
                                    }
                                }
                        }
                        if canEdit { addMenu }
                    } header: {
                        Text("Einlagen")
                    } footer: {
                        Text("Geplante Einlagen spielt das Gerät der Einsatzleitung zur Minute ab Beginn ein; „Jetzt“ sofort. Alle sehen eine Warnmeldung „ÜBUNG – …“. Für die Übungsleitung auf einem zweiten Gerät: Rechte „Voll“ geben.")
                    }
                    if let errorMessage {
                        Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                }
                .navigationTitle("Übungsleitung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
                }
                .sheet(item: $editing) { inject in
                    InjectEditor(inject: inject) { saved in perform(SaveExerciseInject(saved)) }
                }
            }
        }
    }

    // MARK: Punkte

    @ViewBuilder
    private func scoreSection(now: Date) -> some View {
        let state = store.state
        let reports = state.journal.active.filter { $0.category == .situationReport }.count
        if let score = ExerciseScore(mission: state.mission, patients: state.patients, situationReports: reports, now: now) {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(score.total)")
                        .font(.system(size: 44, weight: .heavy).monospacedDigit())
                    Text("von \(score.maximum) Punkten").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    StatusChip(score.rating, systemImage: "rosette", color: score.total * 4 >= score.maximum * 3 ? .green : .orange)
                }
                ForEach(score.parts) { part in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(part.title).font(.headline)
                            Spacer()
                            Text("\(part.points)/\(part.maximum)").font(.headline.monospacedDigit())
                        }
                        ProgressView(value: Double(part.points), total: Double(max(part.maximum, 1)))
                        Text(part.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.xxs)
                }
            } header: {
                Text("Auswertung")
            } footer: {
                Text("Sichtung 40, vollständig 15, Tempo bis zur ersten Sichtung 20, Lagemeldungen 10, Einlagen 15 Punkte.")
            }
        }
    }

    // MARK: Einlagen

    private func row(_ inject: ExerciseInject, now: Date) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: inject.kind.systemImage)
                .font(.title3)
                .foregroundStyle(inject.isReleased ? Color.secondary : Color.purple)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(inject.title).font(.headline).strikethrough(inject.isReleased)
                Text(status(inject, now: now)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            if !inject.isReleased, canEdit {
                Button("Jetzt") { perform(ReleaseExerciseInject(inject.id)) }
                    .font(.headline)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                Button { editing = inject } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Einlage bearbeiten")
            }
        }
        .frame(minHeight: TouchTarget.comfortable)
    }

    private func status(_ inject: ExerciseInject, now: Date) -> String {
        if let released = inject.releasedAt {
            return "eingespielt \(released.formatted(date: .omitted, time: .shortened)) Uhr"
        }
        guard let minute = inject.minute else { return "nur von Hand" }
        let start = store.state.mission.startedAt
        let left = Int(start.addingTimeInterval(TimeInterval(minute * 60)).timeIntervalSince(now) / 60)
        return "Minute \(minute)" + (left > 0 ? " · in \(left) min" : " · fällig")
    }

    private var addMenu: some View {
        Menu {
            Section("Vorlagen") {
                ForEach(ExerciseInject.templates, id: \.title) { template in
                    Button {
                        var copy = template
                        copy.id = UUID()
                        perform(SaveExerciseInject(copy))
                    } label: {
                        Label(template.title, systemImage: template.kind.systemImage)
                    }
                }
            }
            Button {
                editing = ExerciseInject(kind: .message, title: "", text: "", minute: nil)
            } label: {
                Label("Eigene Meldung …", systemImage: "square.and.pencil")
            }
        } label: {
            Label("Einlage hinzufügen", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(minHeight: TouchTarget.minimum)
        }
    }

    private func perform<Command: MissionCommand>(_ command: Command) {
        do {
            _ = try store.perform(command)
            errorMessage = nil
            Haptics.tap()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Titel, Text und Zeitpunkt einer Einlage.
private struct InjectEditor: View {
    @State var inject: ExerciseInject
    let onSave: (ExerciseInject) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var planned = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel (z. B. Presse an der Absperrung)", text: $inject.title).font(.headline)
                    TextField("Meldung an die Einsatzleitung", text: $inject.text, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Toggle("Zu einer Minute einspielen", isOn: $planned)
                    if planned {
                        Stepper("Minute \(inject.minute ?? 10) ab Beginn", value: Binding(
                            get: { inject.minute ?? 10 },
                            set: { inject.minute = $0 }
                        ), in: 0...240, step: 1)
                    }
                } footer: {
                    Text("Ohne Minute nur über „Jetzt“.")
                }
            }
            .navigationTitle(inject.title.isEmpty ? "Neue Einlage" : inject.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        var saved = inject
                        saved.minute = planned ? (inject.minute ?? 10) : nil
                        onSave(saved)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(inject.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { planned = inject.minute != nil || inject.title.isEmpty }
        }
        .presentationDetents([.medium, .large])
    }
}
