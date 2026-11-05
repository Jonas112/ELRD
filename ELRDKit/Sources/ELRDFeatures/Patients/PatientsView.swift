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
                        list(rows, isWide: isWide)
                    }
                    .padding(isWide ? Spacing.xl : Spacing.l)
                    .frame(maxWidth: 1400)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
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
                    ForEach(PatientStatusFilter.allCases) { filter in
                        FilterPill(title: "\(filter.title) \(counts[filter] ?? 0)", isSelected: query.status == filter) {
                            query.status = filter
                        }
                    }
                }
            }
            HStack(spacing: Spacing.s) {
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
                .frame(maxWidth: isWide ? 360 : .infinity)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                if isWide { Spacer() }
                Menu {
                    Picker("Sortierung", selection: $query.sort) {
                        ForEach(PatientSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(query.sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: TouchTarget.minimum + 4)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .accessibilityLabel("Sortierung: \(query.sort.title)")
            }
        }
    }

    // MARK: Liste

    @ViewBuilder
    private func list(_ rows: [PatientRow], isWide: Bool) -> some View {
        if rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(store.state.activePatients.isEmpty
                     ? "Noch keine Patienten. Oben mit einem Tipp anlegen."
                     : "Keine Patienten für diese Auswahl.")
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
        } else {
            LazyVStack(spacing: isWide ? 0 : Spacing.s) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if isWide && index > 0 { Divider() }
                    NavigationLink(value: row.id) {
                        if isWide { WidePatientRow(row: row) } else { CompactPatientRow(row: row) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .background {
                if isWide { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Surface.card) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Patient \(category.displayName) anlegen")
                }
            }
        }
        .padding(isWide ? Spacing.l : 0)
        .background {
            if isWide { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Surface.card) }
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
                .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .layoutPriority(1)
            if let name = row.name {
                Text(name).font(.title3.weight(.bold)).lineLimit(1)
            } else {
                Text("Name unbekannt").font(.title3.weight(.semibold)).italic().foregroundStyle(.secondary).lineLimit(1)
            }
            if row.isDuplicateNumber {
                Text("Nr. doppelt")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .layoutPriority(1)
            }
        }
    }
}

/// Einheit oder Hinweis „keine Einheit“.
struct PatientUnitText: View {
    let row: PatientRow

    var body: some View {
        if !row.hasUnit && row.status == .waiting {
            Label(row.unitText, systemImage: "exclamationmark.circle")
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
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
                HStack(spacing: Spacing.s) {
                    PatientUnitText(row: row)
                    if let destination = row.destination, let registration = row.registration {
                        Text("· \(destination)").lineLimit(1)
                        Text(registration.displayName)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.registration(registration))
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
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}
