import SwiftUI
import ELRDDomain
import ELRDStore

/// Geführte Sichtung (Schritt 87): eine Frage nach der anderen mit großen
/// Ja/Nein-Knöpfen, am Ende ein Vorschlag mit Begründung. Die SK setzt erst der
/// Tipp auf „Übernehmen“ (E104).
struct TriageGuideSheet: View {
    let store: MissionStore
    let patientID: PatientID

    @Environment(\.dismiss) private var dismiss
    @State private var session: TriageSession
    @State private var errorMessage: String?

    init(store: MissionStore, patientID: PatientID, algorithm: TriageAlgorithm) {
        self.store = store
        self.patientID = patientID
        let isChild = store.state.patients.first { $0.id == patientID }?.isChild ?? false
        _session = State(initialValue: TriageSession(algorithm: algorithm, isChild: isChild))
    }

    private var patient: Patient? { store.state.patients.first { $0.id == patientID } }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ProgressView(value: session.progress)
                    .tint(.accentColor)
                if let question = session.current {
                    questionView(question)
                } else if let suggestion = session.suggestion {
                    suggestionView(suggestion)
                }
                Spacer(minLength: 0)
                answeredList
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .background(Surface.canvas)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { withAnimation(.snappy) { session.back() } } label: {
                        Label("Zurück", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(session.answers.isEmpty)
                }
            }
        }
    }

    private var navigationTitle: String {
        let number = patient.map { " – \($0.number)" } ?? ""
        return "Sichtung \(session.algorithm.displayName)\(number)"
    }

    // MARK: Frage

    private func questionView(_ question: TriageQuestion) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Frage \(session.answers.count + 1) von höchstens \(session.questions.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question.text)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if let hint = question.hint {
                Text(hint).font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.m) {
                answerButton("Nein", systemImage: "xmark", tint: .gray) { session.answer(false) }
                answerButton("Ja", systemImage: "checkmark", tint: .accentColor) { session.answer(true) }
            }
            .padding(.top, Spacing.m)
        }
        .id(question.id)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private func answerButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.title.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 96)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .accessibilityLabel(title)
    }

    // MARK: Vorschlag

    private func suggestionView(_ suggestion: TriageSuggestion) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Vorschlag").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: Spacing.l) {
                Text(suggestion.triage.shortName)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(Color(suggestion.triage.color.contrastingTextColor))
                    .frame(minWidth: 140, minHeight: 96)
                    .padding(.horizontal, Spacing.m)
                    .background(Color.triage(suggestion.triage), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(suggestion.triage.displayName).font(.title2.weight(.bold))
                    Text(suggestion.reason).font(.title3).foregroundStyle(.secondary)
                }
            }
            if !suggestion.measures.isEmpty {
                Label(suggestion.measures.joined(separator: " · "), systemImage: "cross.case.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
            }
            if let patient, patient.triage == suggestion.triage {
                Text("Entspricht der bisherigen Kategorie.").font(.subheadline).foregroundStyle(.secondary)
            }
            Button(action: apply) {
                Label("\(suggestion.triage.shortName) übernehmen", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable + 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.triage(suggestion.triage))
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("Nur ein Vorschlag – die Kategorie legt der Sichtende fest. Antworten und Ergebnis stehen nach dem Übernehmen im Protokoll.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    /// Bisherige Antworten (zum Nachvollziehen; „Zurück“ nimmt die letzte zurück).
    @ViewBuilder
    private var answeredList: some View {
        if !session.answers.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(zip(session.questions, session.answers).enumerated()), id: \.offset) { _, pair in
                    HStack {
                        Text(pair.0.short).font(.subheadline)
                        Spacer()
                        Text(pair.1 ? "ja" : "nein").font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.m)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    private func apply() {
        guard let suggestion = session.suggestion else { return }
        do {
            try store.perform(ApplyTriageSuggestion(patientID: patientID, suggestion: suggestion))
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
