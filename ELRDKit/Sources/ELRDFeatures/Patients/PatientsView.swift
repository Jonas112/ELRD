import SwiftUI
import ELRDDomain
import ELRDStore

/// Bereich „Patienten“: Schnellanlage oben, darunter Filter und Liste.
///
/// Offene Patienten stehen oben, sortiert nach SK. Eine Zeile zeigt Nummer und
/// Name groß, darunter ILS-Nummer/Alter/Diagnose; rechts Einheit und Klinik.
struct PatientsView: View {
    let store: MissionStore
    @Binding var query: PatientListQuery
    let onQuickAdd: (Sichtungskategorie) -> Void
    /// Schritt 130: geöffneter Patient in der geteilten Ansicht – dann öffnen Zeilen
    /// direkt über `onOpen` (kein umgebender Navigationsstapel) und er ist markiert.
    var selectedID: PatientID? = nil
    /// Patient öffnen (Board, Kartenscan).
    var onOpen: (PatientID) -> Void = { _ in }

    @State private var showsScanner = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.undoCenter) private var undoCenter
    /// Verbleibsliste (Schritt 93).
    @State private var showsWhereabouts = AppLaunchOptions.current.demoScreen == .whereabouts

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 900
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let patients = query.apply(to: store.state.patients)
                let rows = PatientRow.rows(for: patients, state: store.state, now: context.date)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        if !store.state.mission.isClosed && store.isEnabled(.missionEditing) {
                            QuickAddBar(nextNumber: nextNumber, isWide: isWide, onAdd: onQuickAdd)
                        }
                        filterBar(isWide: isWide)
                        if query.layout == .board {
                            TransportBoardView(store: store, now: context.date, onOpen: onOpen)
                        } else {
                            list(rows, isWide: isWide)
                        }
                    }
                    .padding(isWide ? Spacing.xl : Spacing.l)
                    .frame(maxWidth: 1400)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .sheet(isPresented: $showsScanner) {
            TagScannerSheet(store: store, onOpen: onOpen)
        }
        .sheet(isPresented: $showsWhereabouts) {
            WhereaboutsSheet(store: store, onOpen: onOpen).largeSheet()
        }
    }

    private var nextNumber: String {
        Patient.nextNumber(prefix: store.numberPrefix, existing: store.state.patients).description
    }

    // MARK: Filter

    @ViewBuilder
    private func filterBar(isWide: Bool) -> some View {
        let counts = query.statusCounts(in: store.state.patients)
        VStack(alignment: .leading, spacing: Spacing.m) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    if let triage = query.triage {
                        Button { query.triage = nil } label: {
                            HStack(spacing: Spacing.s) {
                                Text(triage.shortName).fontWeight(.heavy)
                                Image(systemName: "xmark").font(.caption.weight(.bold))
                            }
                            .foregroundStyle(Color.onTriage(triage))
                            .padding(.horizontal, Spacing.l)
                            .frame(minHeight: TouchTarget.minimum + 4)
                            .background(Color.triage(triage), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Filter \(triage.displayName) entfernen")
                    }
                    // Schritt 89: „Mein Abschnitt“ im geteilten Einsatz.
                    if let own = store.state.mission.ownSection(of: store.sessionUserID),
                       let section = store.state.activeSections.first(where: { $0.id == own }) {
                        FilterPill(title: "Mein Abschnitt: \(section.name)", isSelected: query.sectionID == own) {
                            query.sectionID = query.sectionID == own ? nil : own
                        }
                    }
                    ForEach(PatientStatusFilter.allCases) { filter in
                        FilterPill(title: "\(filter.title) \(counts[filter] ?? 0)", isSelected: query.status == filter) {
                            query.status = filter
                        }
                    }
                }
            }
            // iPhone: Suche über die ganze Breite, Knöpfe darunter.
            if isWide {
                HStack(spacing: Spacing.s) {
                    searchField.frame(maxWidth: 360)
                    Spacer()
                    viewControls
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    searchField
                    HStack(spacing: Spacing.s) { viewControls }
                }
            }
        }
    }

    private var searchField: some View {
            HStack(spacing: Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Name, Nummer, ILS-Nr., Merkmal", text: $query.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.searchText.isEmpty {
                    Button { query.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Suche leeren")
                }
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: TouchTarget.minimum + 4)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var viewControls: some View {
        Button { showsScanner = true } label: {
            Image(systemName: "barcode.viewfinder")
                .font(.title3.weight(.semibold))
                .frame(width: TouchTarget.minimum + 8, height: TouchTarget.minimum + 4)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .accessibilityLabel("Anhängekarte scannen")
        Button { showsWhereabouts = true } label: {
            Image(systemName: "person.text.rectangle")
                .font(.title3.weight(.semibold))
                .frame(width: TouchTarget.minimum + 8, height: TouchTarget.minimum + 4)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .accessibilityLabel("Verbleibsliste")
        layoutToggle
        Menu {
            Picker("Sortierung", selection: $query.sort) {
                ForEach(PatientSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            // iPhone: nur Symbol – die Auswahl zeigt das Menü.
            Label(query.sort.title, systemImage: "arrow.up.arrow.down")
                .labelStyle(sizeClass == .compact ? AnyLabelStyle(IconOnlyLabelStyle()) : AnyLabelStyle(TitleAndIconLabelStyle()))
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, sizeClass == .compact ? Spacing.m : Spacing.l)
                .frame(minHeight: TouchTarget.minimum + 4)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .accessibilityLabel("Sortierung: \(query.sort.title)")
    }

    /// Umschalter Liste/Kacheln; die Wahl merkt sich das Gerät.
    private var layoutToggle: some View {
        HStack(spacing: 0) {
            ForEach(PatientListLayout.allCases, id: \.self) { layout in
                Button {
                    query.layout = layout
                    UserDefaults.standard.set(layout.rawValue, forKey: PatientListLayout.storageKey)
                } label: {
                    Image(systemName: layout.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(query.layout == layout ? Color.white : Color.primary)
                        .frame(width: TouchTarget.minimum + 8, height: TouchTarget.minimum + 4)
                        .background(query.layout == layout ? ActionFill.primary : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layout.title)
                .accessibilityAddTraits(query.layout == layout ? .isSelected : [])
            }
        }
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: Liste

    @ViewBuilder
    private func list(_ rows: [PatientRow], isWide: Bool) -> some View {
        if rows.isEmpty && store.state.activePatients.isEmpty {
            // Schritt 136: Leerzustand – angelegt wird oben mit einem Tipp.
            EmptyStateView(
                systemImage: "person.2",
                title: "Noch keine Patienten",
                message: "Oben die Sichtungskategorie antippen – der Patient bekommt sofort die nächste Nummer. Alles Weitere später."
            )
            .cardStyle()
        } else if rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Keine Patienten für diese Auswahl.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if query.isFiltered {
                    Button("Filter zurücksetzen") {
                        query.status = .all
                        query.triage = nil
                        query.searchText = ""
                    }
                    .font(.headline)
                    .frame(minHeight: TouchTarget.minimum)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        } else if query.layout == .tiles {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isWide ? 230 : 200), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(rows) { row in
                    rowLink(row) { PatientTile(row: row) }
                }
            }
        } else {
            LazyVStack(spacing: isWide ? 0 : Spacing.s) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if isWide && index > 0 { Divider() }
                    rowLink(row) {
                        if isWide { WidePatientRow(row: row) } else { CompactPatientRow(row: row) }
                    }
                }
            }
            .background {
                if isWide { RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Surface.card) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        }
    }

    /// Zeile öffnet den Patienten: im Stapel über den Pfad, in der geteilten Ansicht direkt.
    /// Schritt 131: langes Drücken zeigt SK ändern und Öffnen.
    private func rowLink<Label: View>(_ row: PatientRow, @ViewBuilder label: () -> Label) -> some View {
        rowLinkBase(row, label: label)
            .contextMenu { rowMenu(row) }
    }

    @ViewBuilder
    private func rowMenu(_ row: PatientRow) -> some View {
        Button { onOpen(row.id) } label: { Label("Patient \(row.number) öffnen", systemImage: "person.text.rectangle") }
        if !store.state.mission.isClosed {
            Section("Sichtung ändern") {
                ForEach([Sichtungskategorie.sk1, .sk2, .sk3], id: \.self) { triage in
                    Button {
                        setTriage(row, triage)
                    } label: {
                        if row.triage == triage {
                            Label(triage.displayName, systemImage: "checkmark")
                        } else {
                            Text(triage.displayName)
                        }
                    }
                    .disabled(row.triage == triage)
                }
            }
        }
    }

    private func setTriage(_ row: PatientRow, _ triage: Sichtungskategorie) {
        let before = row.triage
        do {
            try store.perform(SetTriage(patientID: row.id, triage: triage))
            Haptics.success()
            let id = row.id
            undoCenter?.offer("\(row.number): \(before.shortName) → \(triage.shortName)", color: Color.triage(triage)) { [store] in
                try store.perform(SetTriage(patientID: id, triage: before))
            }
        } catch {
            Haptics.warning()
        }
    }

    @ViewBuilder
    private func rowLinkBase<Label: View>(_ row: PatientRow, @ViewBuilder label: () -> Label) -> some View {
        if selectedID != nil {
            Button { onOpen(row.id) } label: { label() }
                .buttonStyle(.plain)
                .overlay {
                    if row.id == selectedID {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .accessibilityAddTraits(row.id == selectedID ? .isSelected : [])
        } else {
            NavigationLink(value: row.id) { label() }
                .buttonStyle(.plain)
        }
    }
}

/// Schnellanlage: vier große Knöpfe, ein Tipp = neuer Patient.
struct QuickAddBar: View {
    let nextNumber: String
    let isWide: Bool
    let onAdd: (Sichtungskategorie) -> Void

    var body: some View {
        let layout = isWide
            ? AnyLayout(HStackLayout(spacing: Spacing.m))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
        layout {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Neuer Patient").font(.headline)
                Text("ein Tipp · nächste \(nextNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(width: isWide ? 150 : nil, alignment: .leading)
            HStack(spacing: Spacing.m) {
                ForEach(SituationBar.counterOrder, id: \.self) { category in
                    Button { onAdd(category) } label: {
                        Text(category == .ungesichtet ? (isWide ? "+ ungesichtet" : "+ ?") : "+ \(category.shortName)")
                            .font(.title2.weight(.heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(Color.onTriage(category))
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.large + 4)
                            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Patient \(category.displayName) anlegen")
                }
            }
        }
        .padding(isWide ? Spacing.l : 0)
        .background {
            if isWide { RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Surface.card) }
        }
    }
}

/// Filter-Kapsel („Warten 5“).
struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : .primary)
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: TouchTarget.minimum + 4)
                .background(isSelected ? Color.primary : Surface.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Zeilen

/// SK-Feld links an jeder Zeile.
struct TriageStripe: View {
    let triage: Sichtungskategorie
    var width: CGFloat = 68

    var body: some View {
        Text(triage.shortName)
            .font(.headline.weight(.heavy))
            .foregroundStyle(Color.onTriage(triage))
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(Color.triage(triage))
            .accessibilityLabel(triage.displayName)
    }
}

/// Nummer und Name; lange Namen werden am Ende gekürzt.
struct PatientTitle: View {
    let row: PatientRow

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(row.number)
                .font(.headline.weight(.heavy))
                .monospacedDigit()
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, 3)
                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .layoutPriority(1)
            if let name = row.name {
                Text(name).font(.title3.weight(.bold)).lineLimit(1)
            } else {
                Text("Name unbekannt").font(.title3.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            if row.isDuplicateNumber {
                Text("Nr. doppelt")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .layoutPriority(1)
            }
        }
    }
}

/// Einheit oder Hinweis „keine Einheit“.
struct PatientUnitText: View {
    let row: PatientRow

    var body: some View {
        if !row.hasUnit && row.status == .waiting && row.triage != .sk3 {
            Label(row.unitText, systemImage: "exclamationmark.circle")
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
        } else if !row.hasUnit && row.status == .waiting {
            // Schritt 135: SK 3 ohne Einheit ist normal – nicht in jeder Zeile warnen.
            Text(row.unitText).foregroundStyle(.secondary)
        } else {
            Text(row.unitText).foregroundStyle(row.status == .released ? .secondary : .primary)
        }
    }
}

/// Klinik mit Anmeldestatus.
struct PatientDestinationText: View {
    let row: PatientRow

    var body: some View {
        if let destination = row.destination, let registration = row.registration {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination).lineLimit(1)
                Text(registration.displayName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.registration(registration))
            }
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }
}

/// Zeile für breite Ansichten (iPad quer): Spalten für Einheit und Klinik.
struct WidePatientRow: View {
    let row: PatientRow

    var body: some View {
        HStack(spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                PatientTitle(row: row)
                if !row.details.isEmpty {
                    Text(row.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PatientUnitText(row: row)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
            PatientDestinationText(row: row)
                .frame(width: 220, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.trailing, Spacing.l)
        }
        .padding(.leading, 68 + Spacing.l)
        .frame(minHeight: 78)
        // Als Hintergrund füllt der Streifen die volle Zeilenhöhe.
        .background(alignment: .leading) { TriageStripe(triage: row.triage) }
        .contentShape(Rectangle())
    }
}

/// Zeile für schmale Ansichten (iPad mini hoch): drei Zeilen untereinander.
struct CompactPatientRow: View {
    let row: PatientRow

    var body: some View {
        HStack(spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                PatientTitle(row: row)
                if !row.details.isEmpty {
                    Text(row.details).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                // Passt alles in eine Zeile, sonst Einheit und Klinik untereinander (iPhone).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.s) {
                        PatientUnitText(row: row)
                        destinationLine(prefix: "· ")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        PatientUnitText(row: row)
                        destinationLine(prefix: "")
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.trailing, Spacing.l)
        }
        .padding(.leading, 64 + Spacing.l)
        .frame(minHeight: 92)
        .background(alignment: .leading) { TriageStripe(triage: row.triage, width: 64) }
        .background(Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
    }
}

extension CompactPatientRow {
    @ViewBuilder
    func destinationLine(prefix: String) -> some View {
        if let destination = row.destination, let registration = row.registration {
            HStack(spacing: Spacing.s) {
                Text(prefix + destination).lineLimit(1)
                Text(registration.displayName)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.registration(registration))
                    .fixedSize()
            }
        }
    }
}

/// Kachel für die Kachelansicht: oben SK-Farbe mit großer Nummer, darunter
/// Name, Einheit und Klinik. Entlassene Patienten treten zurück.
struct PatientTile: View {
    let row: PatientRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(row.number)
                    .font(.title.weight(.heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: Spacing.xs)
                if row.isDuplicateNumber {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityLabel("Nummer doppelt")
                }
                Text(row.triage.shortName).font(.headline.weight(.heavy))
            }
            .foregroundStyle(Color.onTriage(row.triage))
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 56)
            .background(Color.triage(row.triage))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let name = row.name {
                    Text(name).font(.headline).lineLimit(2)
                } else {
                    Text("Name unbekannt").font(.headline).foregroundStyle(.secondary).lineLimit(1)
                }
                if !row.details.isEmpty {
                    Text(row.details).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: Spacing.xs)
                PatientUnitText(row: row).font(.subheadline).lineLimit(1)
                if let destination = row.destination, let registration = row.registration {
                    HStack(spacing: Spacing.xs) {
                        Text(destination).lineLimit(1)
                        Text(registration.displayName)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.registration(registration))
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    .font(.subheadline)
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 196)
        .background(Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .opacity(row.status == .released ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
