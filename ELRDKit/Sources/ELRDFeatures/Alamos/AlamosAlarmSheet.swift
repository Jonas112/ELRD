import SwiftUI
import ELRDDomain
import ELRDStore

/// Einzelheiten eines Einsatzes aus Alamos FE2 (Schritt 140): Stichwort, Ort,
/// Alarmtext, Fahrzeuge (mit Stammdaten-Treffer), gemeldete Patienten.
/// Hauptaktion: „Als Einsatz übernehmen“ bzw. „Einsatz öffnen“, wenn schon übernommen.
struct AlamosAlarmSheet: View {
    let alarm: AlamosAlarm
    let masterUnits: [MasterUnit]
    let imported: MissionSummary?
    let canCreate: Bool
    let onImport: () -> Void
    let onOpen: (MissionSummary) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let data = alarm.data
        let matches = AlarmImport(alarm: alarm, masterUnits: masterUnits).vehicleMatches
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack(spacing: Spacing.s) {
                            if let keyword = data.keyword {
                                Text(keyword)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, Spacing.s)
                                    .padding(.vertical, Spacing.xxs)
                                    .background(alarm.isClosed ? Color.gray : Color.red, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            }
                            if alarm.isTest { StatusChip("Test", color: .purple) }
                            if alarm.isClosed { StatusChip("in FE2 geschlossen", color: .gray) }
                        }
                        Text(data.title).font(.title2.weight(.semibold))
                        if let misc = data.keywordMisc { Text(misc).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, Spacing.xs)
                    LabeledContent("Einsatznummer", value: alarm.externalId)
                    LabeledContent("Alarmiert", value: alarm.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    if alarm.revision > 1 {
                        LabeledContent("Zuletzt geändert", value: "\(alarm.updatedAt.formatted(date: .omitted, time: .shortened)) (Stand \(alarm.revision))")
                    }
                    if let sender = alarm.sender { LabeledContent("Absender", value: sender) }
                }

                if let imported {
                    Section {
                        Label("Übernommen als Einsatz \(imported.displayNumber) „\(imported.title)“", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } footer: {
                        Text("Spätere Änderungen aus FE2 (z. B. Nachalarmierungen) bitte im Einsatz von Hand ergänzen.")
                    }
                }

                Section("Einsatzort") {
                    if let address = data.location?.addressLine, !address.isEmpty {
                        Text(address).textSelection(.enabled)
                    }
                    if let coordinate = data.location?.geoCoordinate {
                        LabeledContent("Koordinate", value: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    } else {
                        Text("Keine Koordinate übermittelt.").foregroundStyle(.secondary)
                    }
                }

                if !data.message.isEmpty {
                    Section("Alarmtext") {
                        Text(data.message.joined(separator: "\n"))
                            .textSelection(.enabled)
                    }
                }

                Section {
                    if matches.isEmpty {
                        Text("Keine Fahrzeuge übermittelt.").foregroundStyle(.secondary)
                    }
                    ForEach(matches, id: \.callsign) { match in
                        HStack {
                            Text(match.type.shortName)
                                .font(.caption.weight(.bold))
                                .frame(minWidth: 44)
                                .padding(.vertical, Spacing.xxs)
                                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                            Text(match.callsign)
                            Spacer()
                            if match.master != nil {
                                Label("Stammdaten", systemImage: "checkmark.seal")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("in den Stammdaten")
                            } else {
                                Text("temporär").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Alarmierte Fahrzeuge (\(matches.count))")
                } footer: {
                    if matches.contains(where: { $0.master == nil }) {
                        Text("Fahrzeuge ohne Stammdaten-Eintrag werden als temporäre Einheit angelegt; der Typ ist aus dem Funkrufnamen geschätzt.")
                    }
                }

                if !data.patients.isEmpty {
                    Section("Gemeldete Patienten (\(data.patients.count))") {
                        ForEach(Array(data.patients.enumerated()), id: \.offset) { index, patient in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(patient.name ?? "Patient \(patient.patientNumber ?? String(index + 1))")
                                    .font(.body.weight(.semibold))
                                if let remark = patient.remark { Text(remark).foregroundStyle(.secondary) }
                                if let destination = patient.destination { Text("Ziel: \(destination)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }

                if let caller = data.caller, caller.name != nil || caller.contact != nil {
                    Section("Anrufer") {
                        if let name = caller.name { Text(name) }
                        if let contact = caller.contact { Text(contact).textSelection(.enabled) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Einsatz aus Alamos FE2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.bold)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: Spacing.s) {
            if let imported {
                Button { onOpen(imported) } label: {
                    Label("Einsatz \(imported.displayNumber) öffnen", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                }
                .buttonStyle(PrimaryActionStyle())
            } else if canCreate {
                Button(action: onImport) {
                    Label("Als Einsatz übernehmen", systemImage: "square.and.arrow.down.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                }
                .buttonStyle(PrimaryActionStyle())
            } else {
                Text("Ohne Abo können keine Einsätze angelegt werden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
        .background(.bar)
    }
}
