import SwiftUI
import UIKit
import ELRDDomain
import ELRDStore

/// Kommunikationsplan (Schritt 112): Kanäle, Führung und Abschnitte mit Rufnamen.
/// Daten kommen aus „Führung“ und den Abschnittsleitungen; teilen und drucken.
struct CommunicationPlanSheet: View {
    let store: MissionStore

    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        let plan = CommunicationPlan(store.state)
        NavigationStack {
            List {
                if plan.isEmpty {
                    Section {
                        Text("Noch keine Führung oder Abschnitte erfasst. Funkkanäle und Rufnamen trägst du unter „Führung“ ein.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !plan.channels.isEmpty {
                    Section("Kanäle") {
                        ForEach(plan.channels) { channel in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                                Label(channel.name, systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.headline)
                                    .frame(minWidth: 140, alignment: .leading)
                                Text(channel.members.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: TouchTarget.minimum)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if !plan.leadership.isEmpty {
                    Section("Führung") {
                        ForEach(plan.leadership) { entry in row(entry) }
                    }
                }
                if !plan.sections.isEmpty {
                    Section("Abschnitte") {
                        ForEach(plan.sections) { entry in row(entry) }
                    }
                }
                if !plan.unassignedUnits.isEmpty {
                    Section("Ohne Abschnitt") {
                        Text(plan.unassignedUnits.joined(separator: ", "))
                    }
                }
            }
            .navigationTitle("Kommunikationsplan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { printPlan(plan) } label: { Label("Drucken", systemImage: "printer") }
                        .disabled(plan.isEmpty)
                    Button { sharing = true } label: { Label("Teilen", systemImage: "square.and.arrow.up") }
                        .disabled(plan.isEmpty)
                }
            }
            .sheet(isPresented: $sharing) {
                ShareTextSheet(title: "Kommunikationsplan", text: plan.text, subject: "Kommunikationsplan \(plan.title)",
                               footnote: "Ohne Patientendaten; Namen nur der Führungskräfte.")
                    .largeSheet()
            }
        }
    }

    private func row(_ entry: CommunicationPlan.Entry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.function).font(.headline)
                Spacer()
                if !entry.channel.isEmpty {
                    Text(entry.channel)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            let details = [entry.name, entry.callsign.isEmpty ? "" : "Rufname \(entry.callsign)"].filter { !$0.isEmpty }
            Text(details.isEmpty ? "nicht besetzt" : details.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !entry.units.isEmpty {
                Text(entry.units.joined(separator: ", "))
                    .font(.subheadline)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .frame(minHeight: TouchTarget.minimum)
        .accessibilityElement(children: .combine)
    }

    private func printPlan(_ plan: CommunicationPlan) {
        let stamp = Date().formatted(date: .numeric, time: .shortened)
        let formatter = UIMarkupTextPrintFormatter(markupText: plan.html(printedAt: stamp))
        formatter.perPageContentInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = "Kommunikationsplan \(plan.title)"
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
}
