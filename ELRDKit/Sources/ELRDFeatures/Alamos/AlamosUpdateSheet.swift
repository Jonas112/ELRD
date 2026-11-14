import SwiftUI
import ELRDDomain
import ELRDStore

/// Alle Ereignisse eines neuen FE2-Stands einzeln (Schritt 143/145, E129).
///
/// Oben der empfangene Stand zum Nachlesen, darunter jedes Ereignis mit „Übernehmen“ und
/// „Verwerfen“; je Gruppe „Alle übernehmen“ und unten „Alles übernehmen“. Die Liste
/// aktualisiert sich nach jedem Schritt – Erledigtes verschwindet.
struct AlamosUpdateSheet: View {
    let update: AlarmUpdate
    let canEdit: Bool
    /// Übernehmen bzw. Verwerfen; Fehlertext oder `nil` bei Erfolg.
    let onApply: (AlarmUpdateSelection) -> String?
    let onDiscard: (AlarmUpdateSelection) -> String?

    @State private var errorMessage: String?
    @State private var showsReceived = false
    @Environment(\.dismiss) private var dismiss

    private struct EventGroup: Identifiable {
        let id: String
        let title: String
        let applyAllTitle: String
        let footer: String?
        let events: [AlamosChanges.Event]
    }

    private var groups: [EventGroup] {
        let events = update.events
        func of(_ kinds: AlamosChanges.Event.Kind...) -> [AlamosChanges.Event] { events.filter { kinds.contains($0.kind) } }
        return [
            EventGroup(id: "einsatz", title: "Stichwort und Einsatzort", applyAllTitle: "Beide übernehmen",
                  footer: "Der ELRD-Einsatz behält Stichwort und Ort; die Änderung steht im Tagebuch.", events: of(.keyword, .address)),
            EventGroup(id: "text", title: "Alarmtext", applyAllTitle: "Alle Zeilen übernehmen",
                  footer: "Neue Zeilen werden ins Tagebuch übernommen.", events: of(.message)),
            EventGroup(id: "fahrzeuge", title: "Nachalarmierte Fahrzeuge", applyAllTitle: "Alle Fahrzeuge übernehmen",
                  footer: "Werden im Initialabschnitt angelegt.", events: of(.vehicle)),
            EventGroup(id: "patienten", title: "Gemeldete Patienten", applyAllTitle: "Alle Patienten übernehmen",
                  footer: "Werden ungesichtet angelegt; Bemerkung und Ziel der Leitstelle stehen in der Notiz.", events: of(.patient)),
        ].filter { !$0.events.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DisclosureGroup("Empfangener Stand \(update.alarm.revision) von \(update.alarm.updatedAt.formatted(date: .omitted, time: .shortened))",
                                    isExpanded: $showsReceived) {
                        received(update.alarm.data)
                    }
                } footer: {
                    Text("Unten steht jede Änderung seit der letzten Übernahme einzeln. Verworfenes erscheint nicht wieder.")
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.events) { event in
                            AlamosEventRow(
                                event: event,
                                detail: AlamosEventRow.detail(for: event, in: update),
                                canEdit: canEdit,
                                onApply: { run(onApply, AlarmUpdateSelection(events: [event])) },
                                onDiscard: { run(onDiscard, AlarmUpdateSelection(events: [event])) }
                            )
                        }
                    } header: {
                        HStack {
                            Text("\(group.title) (\(group.events.count))")
                            Spacer()
                            if group.events.count > 1 {
                                Button(group.applyAllTitle) { run(onApply, AlarmUpdateSelection(events: group.events)) }
                                    .font(.subheadline.weight(.semibold))
                                    .textCase(nil)
                                    .disabled(!canEdit)
                            }
                        }
                    } footer: {
                        if let footer = group.footer { Text(footer) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Änderungen aus Alamos FE2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .alert("Nicht möglich", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func run(_ action: (AlarmUpdateSelection) -> String?, _ selection: AlarmUpdateSelection) {
        errorMessage = action(selection)
    }

    /// Was empfangen wurde: der vollständige aktuelle Stand.
    @ViewBuilder
    private func received(_ data: AlamosAlarmData) -> some View {
        LabeledContent("Einsatznummer", value: update.alarm.externalId)
        if let sender = update.alarm.sender { LabeledContent("Absender", value: sender) }
        let keyword = [data.keyword, data.keywordDescription].compactMap { $0 }.joined(separator: " – ")
        LabeledContent("Stichwort", value: keyword.isEmpty ? "–" : keyword)
        if let address = data.location?.addressLine, !address.isEmpty {
            LabeledContent("Einsatzort", value: address)
        }
        if !data.messageLines.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Alarmtext").font(.subheadline).foregroundStyle(.secondary)
                Text(data.messageLines.joined(separator: "\n")).textSelection(.enabled)
            }
        }
        LabeledContent("Fahrzeuge", value: data.callsigns.isEmpty ? "keine" : data.callsigns.joined(separator: ", "))
        LabeledContent("Gemeldete Patienten", value: "\(data.patients.count)")
    }

    private var actionBar: some View {
        Button {
            run(onApply, update.fullSelection)
        } label: {
            Label("Alles übernehmen (\(update.events.count))", systemImage: "square.and.arrow.down.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
        }
        .buttonStyle(PrimaryActionStyle())
        .disabled(!canEdit)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
        .background(.bar)
    }
}
