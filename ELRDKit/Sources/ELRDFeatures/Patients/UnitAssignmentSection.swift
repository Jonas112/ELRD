import SwiftUI
import ELRDDomain

/// Gruppen für die Einheitenwahl beim Patienten.
struct UnitAssignmentGroups: Equatable {
    /// Diesem Patienten zugeordnet.
    let assigned: [UnitChoice]
    /// Freie RTW, KTW, KTW-KatS, RTH.
    let freeTransport: [UnitChoice]
    /// Freie andere Einheiten (NEF, HvO …).
    let freeOther: [UnitChoice]
    /// Schon anderen Patienten zugeordnet.
    let busy: [UnitChoice]

    init(_ choices: [UnitChoice]) {
        assigned = choices.filter(\.isAssigned)
        freeTransport = choices.filter { $0.isFree && $0.unit.type.transportsPatients }
        freeOther = choices.filter { $0.isFree && !$0.unit.type.transportsPatients }
        busy = choices.filter { !$0.isAssigned && !$0.isFree }
    }

    var isEmpty: Bool { assigned.isEmpty && freeTransport.isEmpty && freeOther.isEmpty && busy.isEmpty }
}

/// Einheiten am Patienten, klar gegliedert: oben das Zugeordnete, darunter freie
/// Transportmittel als große Kacheln, dann weitere freie Einheiten; belegte
/// erst auf Wunsch. Ein Tipp ordnet zu bzw. löst.
struct UnitAssignmentSection: View {
    let choices: [UnitChoice]
    let onAssign: (UnitID) -> Void
    let onUnassign: (UnitID) -> Void

    @State private var showsBusy = false

    var body: some View {
        let groups = UnitAssignmentGroups(choices)
        VStack(alignment: .leading, spacing: Spacing.m) {
            if groups.isEmpty {
                Text("Im Einsatz sind noch keine Einheiten. Unter „Einheiten“ hinzufügen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if groups.assigned.isEmpty {
                Label("Noch keine Einheit zugeordnet", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                group("Zugeordnet", groups.assigned) { choice in
                    UnitChoiceTile(choice: choice, style: .assigned) { onUnassign(choice.id) }
                }
            }
            if !groups.freeTransport.isEmpty {
                group("Freie Transportmittel", groups.freeTransport) { choice in
                    UnitChoiceTile(choice: choice, style: .free) { onAssign(choice.id) }
                }
            } else if !groups.isEmpty {
                Text("Kein freies RTW, KTW oder RTH. Unter „Einheiten“ ergänzen oder einen Platzhalter anlegen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !groups.freeOther.isEmpty {
                group("Weitere Einheiten (begleiten, kein Transport)", groups.freeOther) { choice in
                    UnitChoiceTile(choice: choice, style: .free) { onAssign(choice.id) }
                }
            }
            if !groups.busy.isEmpty {
                Button {
                    withAnimation { showsBusy.toggle() }
                } label: {
                    Label(showsBusy ? "Belegte ausblenden" : "Belegte Einheiten zeigen (\(groups.busy.count))",
                          systemImage: showsBusy ? "chevron.up" : "chevron.down")
                        .font(.headline)
                        .frame(minHeight: TouchTarget.minimum)
                }
                if showsBusy {
                    group("Schon bei anderen Patienten", groups.busy) { choice in
                        UnitChoiceTile(choice: choice, style: .busy) { onAssign(choice.id) }
                    }
                }
            }
        }
    }

    private func group(_ title: String, _ items: [UnitChoice], tile: @escaping (UnitChoice) -> UnitChoiceTile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Spacing.s)], spacing: Spacing.s) {
                ForEach(items) { choice in tile(choice) }
            }
        }
    }
}

/// Kachel einer Einheit: Typ-Kennzeichen, Funkrufname, Zustand.
struct UnitChoiceTile: View {
    enum Style { case assigned, free, busy }

    let choice: UnitChoice
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Text(choice.unit.typeDisplayName)
                    .font(.subheadline.weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 52, height: 36)
                    .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Surface.separator, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.unit.displayName)
                        .font(.headline)
                        .foregroundStyle(style == .assigned ? Color.white : Color.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style == .assigned ? Color.white.opacity(0.85) : style == .busy ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: style == .assigned ? "xmark.circle.fill" : "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(style == .assigned ? Color.white : ActionFill.primary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(style == .assigned ? ActionFill.primary : Surface.elevated,
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.unit.typeDisplayName) \(choice.unit.displayName), \(statusText)")
        .accessibilityHint(style == .assigned ? "Tippen löst die Zuordnung." : "Tippen ordnet die Einheit zu.")
    }

    private var statusText: String {
        switch style {
        case .assigned: "zugeordnet · tippen zum Lösen"
        case .free: choice.unit.isPlaceholder ? "frei · Platzhalter" : "frei"
        case .busy: "bei \(choice.otherPatients.joined(separator: ", "))"
        }
    }
}
