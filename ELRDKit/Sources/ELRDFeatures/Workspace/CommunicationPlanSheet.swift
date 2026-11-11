import SwiftUI
import UIKit
import ELRDDomain
import ELRDStore

/// Kommunikationsplan nach FwDV/DV 800 (Schritte 112 und 126): als Liste oder als
/// taktischer Organisations-/Kommunikationsplan (Organigramm). Daten aus „Führung
/// und Kräfte“; benachbarte Kräfte und sonstige Stellen werden hier gepflegt.
struct CommunicationPlanSheet: View {
    let store: MissionStore

    enum Mode: String, CaseIterable, Identifiable {
        case list = "Plan"
        case chart = "Organigramm"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?
    @State private var mode: Mode = AppLaunchOptions.current.demoScreen == .communicationChart ? .chart : .list
    @State private var sharing = false
    @State private var editingLeadership = false
    @State private var editingContact: CommunicationContact?
    @State private var errorMessage: String?

    private var canEdit: Bool { !store.state.mission.isClosed }
    private var issuer: String { appSettings?.settings.organisationName ?? "" }

    var body: some View {
        let plan = CommunicationPlan(store.state)
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Darstellung", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                switch mode {
                case .list: list(plan)
                case .chart: OrganisationChart(plan: plan, compact: sizeClass == .compact)
                }
            }
            .background(Surface.canvas)
            .navigationTitle("Kommunikationsplan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
                ToolbarItemGroup(placement: .primaryAction) {
                    if canEdit {
                        Button { editingLeadership = true } label: {
                            Label("Führung bearbeiten", systemImage: "person.2.badge.gearshape")
                        }
                    }
                    // Ein Knopf für Teilen und Drucken – auf dem iPhone bleibt der Titel lesbar.
                    Menu {
                        Button { sharing = true } label: { Label("Als Text teilen", systemImage: "square.and.arrow.up") }
                        Button { printPlan(plan, chart: false) } label: { Label("Kommunikationsplan drucken (DV 800)", systemImage: "printer") }
                        Button { printPlan(plan, chart: true) } label: { Label("Organigramm drucken (quer)", systemImage: "rectangle.landscape.rotate") }
                    } label: {
                        Label("Teilen oder drucken", systemImage: "square.and.arrow.up")
                    }
                    .disabled(plan.isEmpty)
                }
            }
            .sheet(isPresented: $sharing) {
                ShareTextSheet(title: "Kommunikationsplan", text: plan.text, subject: "Kommunikationsplan \(plan.title)",
                               footnote: "Ohne Patientendaten; enthält Namen und Telefonnummern der Führungskräfte.")
                    .largeSheet()
            }
            .sheet(isPresented: $editingLeadership) { LeadershipSheet(store: store).largeSheet() }
            .sheet(item: $editingContact) { contact in
                ContactEditor(contact: contact, isNew: !(store.state.mission.communicationContacts ?? []).contains { $0.id == contact.id },
                              onSave: save, onDelete: delete)
            }
        }
    }

    // MARK: Liste

    private func list(_ plan: CommunicationPlan) -> some View {
        List {
            if plan.leadership.isEmpty && plan.staff.isEmpty && plan.sections.isEmpty {
                Section {
                    Text("Noch keine Führung oder Abschnitte erfasst. Rufnamen, Rufgruppen und Telefon trägst du unter „Führung bearbeiten“ ein.")
                        .foregroundStyle(.secondary)
                }
            }
            if !plan.channels.isEmpty {
                Section("Rufgruppen") {
                    ForEach(plan.channels) { channel in
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                                channelBadge(channel.name).frame(minWidth: 120, alignment: .leading)
                                Text(channel.members.joined(separator: ", ")).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                channelBadge(channel.name)
                                Text(channel.members.joined(separator: ", ")).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: TouchTarget.minimum)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            entries("Einsatzleitung", plan.leadership)
            entries("Führungsgruppe", plan.staff)
            entries("Einsatzabschnitte", plan.sections)
            contacts("Benachbarte Kräfte", plan.neighbouringForces, neighbour: true)
            contacts("Sonstige Stellen", plan.otherOffices, neighbour: false)
            if !plan.unassignedUnits.isEmpty {
                Section("Ohne Abschnitt") {
                    Text(plan.unassignedUnits.joined(separator: ", "))
                }
            }
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Aufbau nach FwDV/DV 800 („Informations- und Kommunikationstechnik im Einsatz“), Anlage 1.")
            }
        }
    }

    @ViewBuilder
    private func entries(_ title: String, _ entries: [CommunicationPlan.Entry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in row(entry) }
            }
        }
    }

    @ViewBuilder
    private func contacts(_ title: String, _ entries: [CommunicationPlan.Entry], neighbour: Bool) -> some View {
        Section {
            ForEach(entries) { entry in
                Button {
                    editingContact = contact(for: entry)
                } label: {
                    row(entry).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
            }
            if canEdit {
                Menu {
                    ForEach(CommunicationContact.suggestions.filter { $0.neighbour == neighbour }, id: \.name) { suggestion in
                        Button(suggestion.name) {
                            editingContact = CommunicationContact(name: suggestion.name, isNeighbouringForce: neighbour)
                        }
                    }
                    Divider()
                    Button("Andere Stelle …") { editingContact = CommunicationContact(name: "", isNeighbouringForce: neighbour) }
                } label: {
                    Label(neighbour ? "Kräfte hinzufügen" : "Stelle hinzufügen", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(minHeight: TouchTarget.minimum)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if entries.isEmpty {
                Text(neighbour ? "Feuerwehr, Polizei, THW … mit Rufname und Rufgruppe." : "Leitstelle, Behörden, Kliniken – Telefon und E-Mail.")
            }
        }
    }

    private func contact(for entry: CommunicationPlan.Entry) -> CommunicationContact? {
        (store.state.mission.communicationContacts ?? []).first { "contact-\($0.id.uuidString)" == entry.id }
    }

    private func channelBadge(_ name: String) -> some View {
        Label(name, systemImage: "antenna.radiowaves.left.and.right")
            .font(.headline.monospacedDigit())
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
            let reach = [entry.phone.isEmpty ? "" : "Tel. \(entry.phone)", entry.email].filter { !$0.isEmpty }
            if !reach.isEmpty {
                Text(reach.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            }
            if !entry.task.isEmpty {
                Text("Auftrag: \(entry.task)").font(.subheadline)
            }
            if !entry.units.isEmpty {
                Text(entry.units.joined(separator: ", "))
                    .font(.subheadline)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .frame(minHeight: TouchTarget.minimum)
        .accessibilityElement(children: .combine)
    }

    // MARK: Ändern

    private func save(_ contact: CommunicationContact) throws {
        var all = store.state.mission.communicationContacts ?? []
        if let index = all.firstIndex(where: { $0.id == contact.id }) { all[index] = contact } else { all.append(contact) }
        try store.perform(SetCommunicationContacts(all))
        errorMessage = nil
    }

    private func delete(_ contact: CommunicationContact) {
        do {
            try store.perform(SetCommunicationContacts((store.state.mission.communicationContacts ?? []).filter { $0.id != contact.id }))
            errorMessage = nil
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }

    // MARK: Drucken

    private func printPlan(_ plan: CommunicationPlan, chart: Bool) {
        let stamp = Date().formatted(date: .numeric, time: .shortened)
        let markup = chart ? plan.organisationChartHTML(printedAt: stamp, issuer: issuer) : plan.html(printedAt: stamp, issuer: issuer)
        let formatter = UIMarkupTextPrintFormatter(markupText: markup)
        formatter.perPageContentInsets = UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = (chart ? "Organigramm " : "Kommunikationsplan ") + plan.title
        info.outputType = .general
        info.orientation = chart ? .landscape : .portrait
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
}

// MARK: - Sonstige Stelle / benachbarte Kräfte bearbeiten

private struct ContactEditor: View {
    @State var contact: CommunicationContact
    let isNew: Bool
    let onSave: (CommunicationContact) throws -> Void
    let onDelete: (CommunicationContact) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bezeichnung (z. B. Polizei – Einsatzleitung)", text: $contact.name)
                        .font(.headline)
                        .frame(minHeight: TouchTarget.minimum)
                    Picker("Art", selection: $contact.isNeighbouringForce) {
                        Text("Benachbarte Kräfte").tag(true)
                        Text("Sonstige Stelle").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Funk") {
                    TextField("Funkrufname", text: $contact.callsign).frame(minHeight: TouchTarget.minimum)
                    TextField("Rufgruppe (z. B. TMO 312)", text: $contact.channel).frame(minHeight: TouchTarget.minimum)
                }
                Section("Telefon und E-Mail") {
                    TextField("Telefon / Mobil", text: $contact.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .frame(minHeight: TouchTarget.minimum)
                    TextField("E-Mail", text: $contact.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: TouchTarget.minimum)
                }
                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            onDelete(contact)
                            dismiss()
                        } label: {
                            Label("Aus dem Plan entfernen", systemImage: "trash").frame(minHeight: TouchTarget.minimum)
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(isNew ? "Neue Stelle" : contact.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        do {
                            let cleaned = CommunicationContact(id: contact.id, name: contact.name, callsign: contact.callsign, channel: contact.channel,
                                                               phone: contact.phone, email: contact.email, isNeighbouringForce: contact.isNeighbouringForce)
                            guard !cleaned.name.isEmpty else {
                                errorMessage = "Bitte eine Bezeichnung eintragen."
                                return
                            }
                            try onSave(cleaned)
                            dismiss()
                        } catch {
                            errorMessage = ErrorText.message(for: error)
                        }
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Organigramm (taktischer Organisations-/Kommunikationsplan)

/// Einsatzleitung oben (Führungsgruppe gestrichelt daneben), darunter die
/// Einsatzabschnitte mit Verbindungslinien; externe Stellen gestrichelt unten.
struct OrganisationChart: View {
    let plan: CommunicationPlan
    let compact: Bool

    private var boxWidth: CGFloat { compact ? 168 : 210 }
    private let line: CGFloat = 1.5
    private let gap: CGFloat = 22

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .center, spacing: 0) {
                top
                if !plan.sections.isEmpty {
                    Rectangle().fill(Color.primary).frame(width: line, height: gap)
                    sectionRow
                }
                if !plan.neighbouringForces.isEmpty || !plan.otherOffices.isEmpty {
                    external.padding(.top, Spacing.xl)
                }
                if !plan.channels.isEmpty {
                    channels.padding(.top, Spacing.xl)
                }
            }
            .padding(Spacing.l)
            .frame(minWidth: compact ? nil : 600)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Organigramm")
    }

    /// Einsatzleitung mittig; Führungsgruppe rechts, links gleich breiter Platzhalter.
    private var top: some View {
        HStack(alignment: .top, spacing: 0) {
            if !plan.staff.isEmpty { Color.clear.frame(width: boxWidth + gap, height: 1) }
            ChartBox(title: "Einsatzleitung", kind: nil, entries: plan.leadership, compactRows: true, style: .lead, width: boxWidth + 30)
            if !plan.staff.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    DashedLine().stroke(Color.primary, style: StrokeStyle(lineWidth: line, dash: [4, 3]))
                        .frame(width: gap, height: line)
                        .padding(.top, 22)
                    ChartBox(title: "Führungsgruppe", kind: nil, entries: plan.staff, compactRows: true, style: .normal, width: boxWidth)
                }
            }
        }
    }

    private var sectionRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(plan.sections.enumerated()), id: \.element.id) { index, entry in
                VStack(spacing: 0) {
                    // Waagerechte Linie aus zwei Hälften, damit sie über alle Spalten läuft.
                    HStack(spacing: 0) {
                        Rectangle().fill(index == 0 ? Color.clear : Color.primary).frame(height: line)
                        Rectangle().fill(index == plan.sections.count - 1 ? Color.clear : Color.primary).frame(height: line)
                    }
                    Rectangle().fill(Color.primary).frame(width: line, height: gap - line)
                    ChartBox(title: entry.function, kind: "EA", entries: [entry], compactRows: false, style: .normal, width: boxWidth)
                        .padding(.horizontal, Spacing.s)
                }
            }
        }
    }

    private var external: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Benachbarte Kräfte und sonstige Stellen").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: boxWidth, maximum: boxWidth), spacing: Spacing.m, alignment: .top)],
                      alignment: .leading, spacing: Spacing.m) {
                ForEach(plan.neighbouringForces) { entry in
                    ChartBox(title: entry.function, kind: "Benachbarte Kräfte", entries: [entry], compactRows: false, style: .dashed, width: boxWidth)
                }
                ForEach(plan.otherOffices) { entry in
                    ChartBox(title: entry.function, kind: "Sonstige Stelle", entries: [entry], compactRows: false, style: .dashed, width: boxWidth)
                }
            }
        }
        .frame(maxWidth: max(boxWidth, CGFloat(plan.sections.count) * (boxWidth + 2 * Spacing.s)), alignment: .leading)
    }

    private var channels: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Rufgruppen").font(.headline)
            ForEach(plan.channels) { channel in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    Text(channel.name)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
                    Text(channel.members.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: max(boxWidth * 2, CGFloat(plan.sections.count) * (boxWidth + 2 * Spacing.s)), alignment: .leading)
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct ChartBox: View {
    enum Style { case lead, normal, dashed }

    let title: String
    let kind: String?
    let entries: [CommunicationPlan.Entry]
    /// Einsatzleitung: je Funktion eine Zeile.
    let compactRows: Bool
    let style: Style
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let kind {
                    Text(kind).font(.caption2.weight(.semibold)).opacity(0.8)
                }
                Text(title).font(.subheadline.weight(.bold)).lineLimit(2)
            }
            .foregroundStyle(style == .dashed ? Color.primary : Color.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(style == .dashed ? Color.secondary.opacity(0.15) : Color(red: 0.13, green: 0.2, blue: 0.33))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if entries.isEmpty {
                    Text("nicht besetzt").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    if compactRows {
                        Text("\(Text(entry.function).bold()) \(entry.name)").font(.caption)
                    } else if !entry.name.isEmpty {
                        Text("Ltg.: \(entry.name)").font(.caption)
                    }
                    if !entry.callsign.isEmpty {
                        Text(entry.callsign).font(.caption.weight(.bold))
                    }
                    if !entry.channel.isEmpty {
                        Label(entry.channel, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption.monospacedDigit())
                    }
                    if !entry.phone.isEmpty {
                        Label(entry.phone, systemImage: "phone").font(.caption)
                    }
                    if !entry.email.isEmpty {
                        Label(entry.email, systemImage: "envelope").font(.caption).lineLimit(1)
                    }
                    if !entry.task.isEmpty {
                        Text("Auftrag: \(entry.task)").font(.caption).italic().lineLimit(3)
                    }
                    if !entry.units.isEmpty {
                        Text(entry.units.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if !compactRows, entry.isVacant, entry.channel.isEmpty {
                        Text("Leitung nicht besetzt").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, alignment: .topLeading)
        .background(Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(Color.primary.opacity(style == .dashed ? 0.7 : 1),
                        style: StrokeStyle(lineWidth: style == .lead ? 2.5 : 1.2, dash: style == .dashed ? [5, 3] : []))
        }
        .accessibilityElement(children: .combine)
    }
}
