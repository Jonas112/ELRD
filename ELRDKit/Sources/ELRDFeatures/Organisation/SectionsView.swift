import SwiftUI
import UIKit
import ELRDDomain
import ELRDStore

/// Bereich „Einheiten“: je Abschnitt eine Karte mit seinen Einheiten und deren
/// Patienten. Oben Hinzufügen, Typfilter und Suche. Einheiten und Patienten ohne
/// Einheit lassen sich ziehen (`DropAction`); ein Tipp öffnet dasselbe als Menü.
struct SectionsView: View {
    let store: MissionStore
    let templates: MasterDataEditor?
    let onOpenPatient: (PatientID) -> Void

    @State private var showsAddSection = false
    @State private var showsAddUnit = [.addUnit, .addPlaceholder].contains(AppLaunchOptions.current.demoScreen)
    @State private var filter = UnitFilter()
    @State private var removing: MissionUnit?
    @State private var replacing: MissionUnit?
    @State private var renaming: MissionSection?
    @State private var newName = ""
    @State private var deleting: MissionSection?
    @State private var errorMessage: String?

    private var canEdit: Bool { !store.state.mission.isClosed && store.isEnabled(.missionEditing) }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 900
            let allColumns = SectionColumn.columns(for: store.state)
            let columns = allColumns.compactMap { $0.filtered(by: filter) }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(columns: allColumns)
                    if !store.state.activeUnits.isEmpty { filterBar(isWide: isWide) }
                    if allColumns.isEmpty {
                        emptyState
                    } else if columns.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            Text("Keine Einheit passt zur Auswahl.").font(.title3).foregroundStyle(.secondary)
                            Button("Filter zurücksetzen") { filter = UnitFilter() }
                                .font(.headline)
                                .frame(minHeight: TouchTarget.minimum)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
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
                                    onDelete: { deleting = $0 },
                                    onRemoveUnit: { removing = $0 },
                                    onReplace: { replacing = $0 },
                                    onArrived: { unit in perform(MarkUnitArrived(unitID: unit)) },
                                    onArrival: { unit, minutes in perform(SetExpectedArrival(unitID: unit, minutes: minutes)) },
                                    onDrop: handleDrop
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
        .sheet(isPresented: $showsAddUnit) {
            AddUnitSheet(
                store: store,
                masterData: templates,
                initialSource: AppLaunchOptions.current.demoScreen == .addPlaceholder ? .placeholder : nil
            )
            .largeSheet()
        }
        .sheet(item: $replacing) { unit in
            ReplacePlaceholderSheet(store: store, masterData: templates, placeholder: unit)
                .largeSheet()
        }
        .onAppear {
            if AppLaunchOptions.current.demoScreen == .replacePlaceholder, replacing == nil {
                replacing = MissionUnit.sorted(store.state.activeUnits).first(where: \.isPlaceholder)
            }
        }
        .confirmationDialog(
            removing.map { "\($0.displayName) aus dem Einsatz entfernen?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Entfernen", role: .destructive) {
                if let unit = removing { perform(RemoveUnit(unitID: unit.id)) }
                removing = nil
            }
        } message: {
            Text("Die Einheit erscheint danach nicht mehr im Einsatz; das Protokoll behält den Eintrag.")
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
        // iPhone: Knöpfe unter den Titel, damit nichts umbricht.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.m) {
                headerTitle(columns)
                Spacer(minLength: Spacing.s)
                headerButtons
            }
            VStack(alignment: .leading, spacing: Spacing.m) {
                headerTitle(columns)
                headerButtons
            }
        }
    }

    private func headerTitle(_ columns: [SectionColumn]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Abschnitte").font(.title2.weight(.bold))
            Text(summary(columns)).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var headerButtons: some View {
        if canEdit {
            HStack(spacing: Spacing.m) {
                Button { showsAddSection = true } label: {
                    Label("Abschnitt", systemImage: "plus")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.comfortable)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abschnitt hinzufügen")
                Button { showsAddUnit = true } label: {
                    Label("Einheit", systemImage: "plus")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.comfortable)
                        .background(ActionFill.primary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Einheit hinzufügen")
            }
        }
    }

    /// Typfilter mit Zählern und Suche (wie in der Patientenliste).
    private func filterBar(isWide: Bool) -> some View {
        let units = store.state.activeUnits
        let counts = UnitFilter.counts(units, search: filter.search, type: \.type) { "\($0.displayName) \($0.typeDisplayName)" }
        let layout = isWide
            ? AnyLayout(HStackLayout(spacing: Spacing.m))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
        return layout {
            UnitSearchField(text: $filter.search)
                .frame(maxWidth: isWide ? 320 : .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(UnitTypeFilter.allCases) { type in
                        if type == .all || (counts[type] ?? 0) > 0 || filter.type == type {
                            FilterPill(title: "\(type.title) \(counts[type] ?? 0)", isSelected: filter.type == type) {
                                filter.type = type
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Noch keine Abschnitte und Einheiten.").font(.title3)
            Text("Abschnitte gliedern die Einsatzstelle, z. B. Bereitstellungsraum oder Patientenablage. Neue Einheiten kommen in den Initialabschnitt. Einheiten oben über „+ Einheit“ aus den Stammdaten wählen oder neu anlegen.")
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
            do { try templates?.save(request.name) } catch { errorMessage = "Vorlage nicht gespeichert: \(ErrorText.message(for: error))" }
        }
    }

    /// Führt ein Ablegen aus; bei einem Fehler bleibt der Rest ungetan.
    private func handleDrop(_ payload: DragPayload, onto target: DropTarget) -> Bool {
        let actions = DropAction.actions(for: payload, onto: target, in: store.state)
        guard !actions.isEmpty else { return false }
        do {
            for action in actions {
                switch action {
                case .moveUnit(let unitID, let sectionID):
                    try store.perform(MoveUnit(unitID: unitID, to: sectionID))
                case .movePatient(let patientID, let sectionID):
                    try store.perform(MovePatient(patientID: patientID, to: sectionID))
                case .assign(let patientID, let unitID):
                    try store.perform(AssignUnit(patientID: patientID, unitID: unitID))
                }
            }
            return true
        } catch {
            errorMessage = ErrorText.message(for: error)
            return false
        }
    }

    private func perform<Command: MissionCommand>(_ command: Command) {
        do {
            _ = try store.perform(command)
        } catch {
            errorMessage = ErrorText.message(for: error)
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
    let onRemoveUnit: (MissionUnit) -> Void
    let onReplace: (MissionUnit) -> Void
    /// Schritt 92: erwartetes Eintreffen.
    var onArrived: (UnitID) -> Void = { _ in }
    var onArrival: (UnitID, Int?) -> Void = { _, _ in }
    let onDrop: (DragPayload, DropTarget) -> Bool

    /// Einheit, deren Aktionen nach einem Tipp angeboten werden.
    @State private var actionEntry: UnitEntry?

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
                                .organisationDraggable(canEdit ? .patient(badge.id) : nil) { PatientBadgeView(badge: badge) }
                                .organisationDrop(isEnabled: canEdit, cornerRadius: Radius.control) {
                                    onDrop($0, .loosePatient(badge.id, section: column.section?.id))
                                }
                        }
                    }
                }
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay {
            if column.section == nil {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        .organisationDrop(isEnabled: canEdit, cornerRadius: Radius.large) { onDrop($0, .section(column.section?.id)) }
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

    /// Einheit als Zeile: ziehbar und Ablagefläche (Patient → zuordnen).
    private func unitRow(_ entry: UnitEntry) -> some View {
        unitRowContent(entry)
            .overlay(alignment: .trailing) {
                if canEdit { statusMenu(entry.unit).padding(.trailing, Spacing.s) }
            }
            .organisationDraggable(canEdit ? .unit(entry.unit.id) : nil) {
                UnitRowLabel(entry: entry, showsMoveHint: false).frame(width: 300)
            }
            .organisationDrop(isEnabled: canEdit, cornerRadius: Radius.card) { onDrop($0, .unit(entry.unit.id)) }
    }

    /// Tipp öffnet „Verschieben nach …“ (Platzhalter: gleich „Fahrzeug eintragen“).
    /// Halten und Ziehen verschiebt per Drag & Drop; Halten ohne Ziehen zeigt das Menü.
    /// Ein `Menu` als Zeile hätte die Berührung selbst behalten – dann ließ sich
    /// nichts ziehen (Jonas).
    @ViewBuilder
    private func unitRowContent(_ entry: UnitEntry) -> some View {
        let row = UnitRowLabel(entry: entry, showsMoveHint: canEdit, reservesStatusSpace: canEdit)
        if canEdit {
            Button {
                if entry.unit.isPlaceholder { onReplace(entry.unit) } else { actionEntry = entry }
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { unitMenu(entry) }
            .confirmationDialog(
                actionEntry.map { "\($0.unit.typeDisplayName) \($0.unit.displayName)" } ?? "",
                isPresented: Binding(
                    get: { actionEntry?.unit.id == entry.unit.id },
                    set: { if !$0 { actionEntry = nil } }
                ),
                titleVisibility: .visible
            ) {
                unitDialogButtons(entry)
            } message: {
                Text("Tipp auf ein Ziel verschiebt. Tipp: Zeile halten und auf einen Abschnitt ziehen.")
            }
        } else {
            row
        }
    }

    /// Aktionen im Dialog (ohne Gruppen – Dialoge kennen keine Abschnitte).
    @ViewBuilder
    private func unitDialogButtons(_ entry: UnitEntry) -> some View {
        ForEach(sections.filter { $0.id != entry.unit.sectionID }) { target in
            Button("Nach „\(target.name)“ verschieben") { onMove(entry.unit.id, target.id) }
        }
        if column.section != nil {
            Button("Nach „Ohne Abschnitt“ verschieben") { onMove(entry.unit.id, nil) }
        }
        ForEach(entry.patients) { badge in
            Button("Patient \(badge.number) öffnen") { onOpenPatient(badge.id) }
        }
        if entry.patients.isEmpty {
            Button("Aus dem Einsatz entfernen", role: .destructive) { onRemoveUnit(entry.unit) }
        }
        Button("Abbrechen", role: .cancel) {}
    }

    /// Erwartetes Eintreffen (Schritt 92).
    private func statusMenu(_ unit: MissionUnit) -> some View {
        Menu {
            if unit.expectedArrival != nil {
                Button("Eingetroffen", systemImage: "checkmark.circle") { onArrived(unit.id) }
            }
            Section("Eintreffen erwartet") {
                ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                    Button("in \(minutes) min") { onArrival(unit.id, minutes) }
                }
                if unit.expectedArrival != nil {
                    Button("Keine Angabe") { onArrival(unit.id, nil) }
                }
            }
        } label: {
            ArrivalBadge(unit: unit)
        }
        .accessibilityLabel("Eintreffen von \(unit.displayName)")
    }

    @ViewBuilder
    private func unitMenu(_ entry: UnitEntry) -> some View {
        if entry.unit.isPlaceholder {
            Button { onReplace(entry.unit) } label: { Label("Fahrzeug eintragen", systemImage: "car.fill") }
        }
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
        Section {
            Button(role: .destructive) { onRemoveUnit(entry.unit) } label: {
                Label("Aus dem Einsatz entfernen", systemImage: "minus.circle")
            }
            .disabled(!entry.patients.isEmpty)
        }
    }
}

/// Inhalt einer Einheitenzeile: Typ, Name, Patienten.
struct UnitRowLabel: View {
    let entry: UnitEntry
    let showsMoveHint: Bool
    /// Platz rechts für das Statusmenü (Schritt 91).
    var reservesStatusSpace = false
    @Environment(AppSettingsStore.self) private var appSettings: AppSettingsStore?

    var body: some View {
        HStack(spacing: Spacing.m) {
            // Eigenes Fahrzeugbild aus den Einstellungen (wie ELRDRG), sonst nur das Kennzeichen.
            if let data = appSettings?.settings.image(for: entry.unit.type), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 36)
                    .accessibilityHidden(true)
            }
            Text(entry.unit.typeDisplayName)
                .font(.subheadline.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 52, height: 36)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Surface.separator, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.unit.displayName)
                    .font(.headline)
                    .foregroundStyle(entry.unit.isPlaceholder ? .secondary : .primary)
                    .lineLimit(1)
                if entry.unit.isPlaceholder, showsMoveHint {
                    Text("Tippen: Fahrzeug eintragen")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                ArrivalLine(unit: entry.unit)
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
            if reservesStatusSpace {
                Color.clear.frame(width: 56, height: 1)
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 60)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            if entry.unit.isPlaceholder {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
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
            .background(Color.triage(badge.triage), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
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
                .background(Color.triage(badge.triage), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Patient \(badge.number), \(badge.triage.displayName) öffnen")
    }
}

/// Suchfeld für Funkrufnamen.
struct UnitSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Funkrufname suchen", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Suche leeren")
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: TouchTarget.minimum + 4)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Kleines Feld mit erwarteter Ankunftszeit bzw. „ETA“ (Schritt 92).
struct ArrivalBadge: View {
    let unit: MissionUnit

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let overdue = unit.isArrivalOverdue(now: context.date)
            Text(unit.expectedArrival.map { $0.formatted(date: .omitted, time: .shortened) } ?? "ETA")
                .font(.subheadline.weight(.heavy).monospacedDigit())
                .foregroundStyle(unit.expectedArrival == nil ? Color.secondary : .white)
                .frame(width: 56, height: 40)
                .background(unit.expectedArrival == nil ? Surface.card : (overdue ? Color.red : Color.orange),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Surface.separator, lineWidth: unit.expectedArrival == nil ? 1 : 0))
        }
    }
}

/// Zeile unter dem Fahrzeugnamen: erwartetes Eintreffen.
struct ArrivalLine: View {
    let unit: MissionUnit

    var body: some View {
        if let expected = unit.expectedArrival {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let overdue = unit.isArrivalOverdue(now: context.date)
                let minutes = Int(abs(expected.timeIntervalSince(context.date)) / 60)
                Label(
                    overdue
                        ? "Eintreffen \(expected.formatted(date: .omitted, time: .shortened)) – \(minutes) min überfällig"
                        : "Eintreffen \(expected.formatted(date: .omitted, time: .shortened)) (in \(minutes) min)",
                    systemImage: "clock"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(overdue ? Color.red : Color.orange)
            }
        }
    }
}
