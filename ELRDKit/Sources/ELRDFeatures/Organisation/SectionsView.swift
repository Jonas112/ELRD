import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereich „Einheiten“, Teil Abschnitte: je Abschnitt eine Karte mit seinen
/// Einheiten und deren Patienten. Ein Tipp auf eine Einheit verschiebt sie.
///
/// Einheiten hinzufügen, Filter und Suche folgen in Schritt 25, Ziehen in 27.
struct SectionsView: View {
    let store: MissionStore
    let templates: SectionTemplates?
    let onOpenPatient: (PatientID) -> Void

    @State private var showsAddSection = false
    @State private var renaming: MissionSection?
    @State private var newName = ""
    @State private var deleting: MissionSection?
    @State private var errorMessage: String?

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 900
            let columns = SectionColumn.columns(for: store.state)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(columns: columns)
                    if columns.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: isWide ? 320 : 300), spacing: Spacing.m, alignment: .top)],
                            alignment: .leading,
                            spacing: Spacing.m
                        ) {
                            ForEach(columns) { column in
                                SectionCard(
                                    column: column,
                                    sections: store.state.activeSections,
                                    canEdit: canEdit,
                                    onMove: { unit, target in perform(MoveUnit(unitID: unit, to: target)) },
                                    onOpenPatient: onOpenPatient,
                                    onRename: { section in newName = section.name; renaming = section },
                                    onMakeInitial: { perform(SetInitialSection(sectionID: $0)) },
                                    onDelete: { deleting = $0 }
                                )
                            }
                        }
                    }
                }
                .padding(isWide ? Spacing.xl : Spacing.l)
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showsAddSection) {
            AddSectionSheet(
                existing: store.state.activeSections,
                templates: templates,
                onAdd: addSection
            )
        }
        .alert("Abschnitt umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Umbenennen") {
                if let section = renaming { perform(RenameSection(sectionID: section.id, name: newName)) }
                renaming = nil
            }
        }
        .confirmationDialog(
            deleting.map { "Abschnitt „\($0.name)“ löschen?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Abschnitt löschen", role: .destructive) {
                if let section = deleting { perform(DeleteSection(sectionID: section.id)) }
                deleting = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .alert("Nicht gespeichert", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func header(columns: [SectionColumn]) -> some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Abschnitte").font(.title2.weight(.bold))
                Text(summary(columns)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            if canEdit {
                Button { showsAddSection = true } label: {
                    Label("Abschnitt", systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.comfortable)
                        .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abschnitt hinzufügen")
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Noch keine Abschnitte und Einheiten.").font(.title3)
            Text("Abschnitte gliedern die Einsatzstelle, z. B. Bereitstellungsraum oder Patientenablage. Neue Einheiten kommen in den Initialabschnitt.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func summary(_ columns: [SectionColumn]) -> String {
        let sections = store.state.activeSections.count
        let units = columns.reduce(0) { $0 + $1.units.count }
        let sectionText = sections == 1 ? "1 Abschnitt" : "\(sections) Abschnitte"
        let unitText = units == 1 ? "1 Einheit" : "\(units) Einheiten"
        return "\(sectionText) · \(unitText)"
    }

    private var deleteMessage: String {
        guard let section = deleting else { return "" }
        let count = store.state.activeUnits.filter { $0.sectionID == section.id }.count
        let units = count == 0 ? "Er enthält keine Einheiten." : count == 1
            ? "Die Einheit darin steht danach „ohne Abschnitt“."
            : "Die \(count) Einheiten darin stehen danach „ohne Abschnitt“."
        return section.isInitial ? "\(units) Danach gibt es keinen Initialabschnitt." : units
    }

    private func addSection(_ request: AddSectionSheet.Request) {
        perform(AddSection(name: request.name, masterSectionID: request.masterSectionID, makeInitial: request.makeInitial))
        if request.saveAsTemplate {
            do { try templates?.save(request.name) } catch { errorMessage = "Vorlage nicht gespeichert: \(error.localizedDescription)" }
        }
    }

    private func perform<Command: MissionCommand>(_ command: Command) {
        do {
            _ = try store.perform(command)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Karte eines Abschnitts: Kopf mit Name, Initial-Kennzeichen und Menü;
/// darunter die Einheiten (Tipp = verschieben) und lose Patienten.
struct SectionCard: View {
    let column: SectionColumn
    let sections: [MissionSection]
    let canEdit: Bool
    let onMove: (UnitID, SectionID?) -> Void
    let onOpenPatient: (PatientID) -> Void
    let onRename: (MissionSection) -> Void
    let onMakeInitial: (SectionID?) -> Void
    let onDelete: (MissionSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            head
            ForEach(column.units) { entry in
                unitRow(entry)
            }
            if !column.loosePatients.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Patienten ohne Einheit").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    FlowLayout(spacing: Spacing.xs) {
                        ForEach(column.loosePatients) { badge in
                            PatientBadgeButton(badge: badge) { onOpenPatient(badge.id) }
                        }
                    }
                }
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if column.section == nil {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
    }

    private var head: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    Text(column.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(column.section == nil ? Color.orange : Color.primary)
                        .lineLimit(2)
                    if column.isInitial {
                        Text("Initial")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(ActionFill.primary, in: Capsule())
                            .accessibilityLabel("Initialabschnitt: neue Einheiten kommen hierher")
                    }
                }
                Text(column.typeSummary.isEmpty ? "keine Einheiten" : column.typeSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.xs)
            if let section = column.section, canEdit {
                Menu {
                    Button { onRename(section) } label: { Label("Umbenennen", systemImage: "pencil") }
                    if section.isInitial {
                        Button { onMakeInitial(nil) } label: { Label("Nicht mehr Initialabschnitt", systemImage: "star.slash") }
                    } else {
                        Button { onMakeInitial(section.id) } label: { Label("Als Initialabschnitt", systemImage: "star") }
                    }
                    Divider()
                    Button(role: .destructive) { onDelete(section) } label: { Label("Löschen", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.bold))
                        .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                        .background(Surface.elevated, in: Circle())
                }
                .accessibilityLabel("Abschnitt \(section.name) bearbeiten")
            }
        }
    }

    /// Einheit als Zeile; Tipp öffnet „Verschieben nach …“.
    @ViewBuilder
    private func unitRow(_ entry: UnitEntry) -> some View {
        let row = UnitRowLabel(entry: entry, showsMoveHint: canEdit)
        if canEdit {
            Menu {
                Section("\(entry.unit.displayName) verschieben nach") {
                    ForEach(sections.filter { $0.id != entry.unit.sectionID }) { target in
                        Button(target.name) { onMove(entry.unit.id, target.id) }
                    }
                    if column.section != nil {
                        Button("Ohne Abschnitt") { onMove(entry.unit.id, nil) }
                    }
                }
                if !entry.patients.isEmpty {
                    Section("Patient öffnen") {
                        ForEach(entry.patients) { badge in
                            Button("Patient \(badge.number) · \(badge.triage.shortName)") { onOpenPatient(badge.id) }
                        }
                    }
                }
            } label: { row }
            .buttonStyle(.plain)
        } else {
            row
        }
    }
}

/// Inhalt einer Einheitenzeile: Typ, Name, Patienten.
struct UnitRowLabel: View {
    let entry: UnitEntry
    let showsMoveHint: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(entry.unit.type.shortName)
                .font(.subheadline.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 52, height: 36)
                .background(Surface.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.unit.displayName)
                    .font(.headline)
                    .foregroundStyle(entry.unit.isPlaceholder ? .secondary : .primary)
                    .lineLimit(1)
                if !entry.patients.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        ForEach(entry.patients.prefix(4)) { badge in PatientBadgeView(badge: badge) }
                        if entry.patients.count > 4 {
                            Text("+\(entry.patients.count - 4)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsMoveHint {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 60)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Patientennummer auf SK-Farbe.
struct PatientBadgeView: View {
    let badge: PatientBadge

    var body: some View {
        Text(badge.number)
            .font(.caption.weight(.heavy))
            .monospacedDigit()
            .foregroundStyle(Color.onTriage(badge.triage))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.triage(badge.triage), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Patient \(badge.number), \(badge.triage.displayName)")
    }
}

/// Größeres, antippbares Patienten-Abzeichen.
struct PatientBadgeButton: View {
    let badge: PatientBadge
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(badge.number)
                .font(.headline.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(Color.onTriage(badge.triage))
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: TouchTarget.minimum)
                .background(Color.triage(badge.triage), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Patient \(badge.number), \(badge.triage.displayName) öffnen")
    }
}
