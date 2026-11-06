import Foundation
import SwiftUI
import ELRDDomain
import ELRDStore

/// Was gezogen wird. Als Text übertragen („elrd-unit:<UUID>“), damit kein eigener
/// Dateityp in der Info.plist nötig ist; fremder Text wird ignoriert.
enum DragPayload: Equatable {
    case unit(UnitID)
    case patient(PatientID)
    /// Abschnitt aus der Liste neben der Karte (Schritt 29).
    case section(SectionID)

    private static let unitPrefix = "elrd-unit:"
    private static let patientPrefix = "elrd-patient:"
    private static let sectionPrefix = "elrd-section:"

    var text: String {
        switch self {
        case .unit(let id): Self.unitPrefix + id.rawValue.uuidString
        case .patient(let id): Self.patientPrefix + id.rawValue.uuidString
        case .section(let id): Self.sectionPrefix + id.rawValue.uuidString
        }
    }

    init?(text: String) {
        if text.hasPrefix(Self.unitPrefix), let id = UnitID(uuidString: String(text.dropFirst(Self.unitPrefix.count))) {
            self = .unit(id)
        } else if text.hasPrefix(Self.patientPrefix), let id = PatientID(uuidString: String(text.dropFirst(Self.patientPrefix.count))) {
            self = .patient(id)
        } else if text.hasPrefix(Self.sectionPrefix), let id = SectionID(uuidString: String(text.dropFirst(Self.sectionPrefix.count))) {
            self = .section(id)
        } else {
            return nil
        }
    }
}

/// Wohin gezogen wird.
enum DropTarget: Equatable {
    /// Abschnittskarte (`nil`: „Ohne Abschnitt“).
    case section(SectionID?)
    /// Einheitenzeile.
    case unit(UnitID)
    /// Patient ohne Einheit (liegt im Abschnitt).
    case loosePatient(PatientID, section: SectionID?)
}

/// Ergebnis eines Ablegens, als Folge von Befehlen (wie ELRDRG-Organisation):
/// Einheit → Abschnitt verschiebt; Einheit → Einheit verschiebt in deren Abschnitt;
/// Einheit → Patient ohne Einheit ordnet zu und holt die Einheit in seinen Abschnitt;
/// Patient → Einheit ordnet zu; Patient → Abschnitt legt ihn dort ab.
enum DropAction: Equatable {
    case moveUnit(UnitID, to: SectionID?)
    case movePatient(PatientID, to: SectionID?)
    case assign(patient: PatientID, unit: UnitID)

    static func actions(for payload: DragPayload, onto target: DropTarget, in state: MissionState) -> [DropAction] {
        let units = state.activeUnits
        switch payload {
        case .unit(let draggedID):
            guard let dragged = units.first(where: { $0.id == draggedID }) else { return [] }
            switch target {
            case .section(let sectionID):
                return dragged.sectionID == sectionID ? [] : [.moveUnit(draggedID, to: sectionID)]
            case .unit(let targetID):
                guard targetID != draggedID, let other = units.first(where: { $0.id == targetID }) else { return [] }
                return dragged.sectionID == other.sectionID ? [] : [.moveUnit(draggedID, to: other.sectionID)]
            case .loosePatient(let patientID, let sectionID):
                var result: [DropAction] = [.assign(patient: patientID, unit: draggedID)]
                if dragged.sectionID != sectionID { result.append(.moveUnit(draggedID, to: sectionID)) }
                return result
            }
        case .patient(let patientID):
            switch target {
            case .section(let sectionID): return [.movePatient(patientID, to: sectionID)]
            case .unit(let unitID): return [.assign(patient: patientID, unit: unitID)]
            case .loosePatient: return []
            }
        case .section:
            return []
        }
    }
}

// MARK: - Oberfläche

extension View {
    /// Macht eine Zeile ziehbar (`nil`: nicht ziehbar, z. B. ohne Bearbeitungsrecht).
    @ViewBuilder
    func organisationDraggable<Preview: View>(_ payload: DragPayload?, @ViewBuilder preview: () -> Preview) -> some View {
        if let payload {
            draggable(payload.text, preview: preview)
        } else {
            self
        }
    }

    /// Ablagefläche mit deutlichem Rahmen, solange etwas darüber gehalten wird.
    func organisationDrop(isEnabled: Bool, cornerRadius: CGFloat, perform: @escaping (DragPayload) -> Bool) -> some View {
        modifier(OrganisationDropModifier(isEnabled: isEnabled, cornerRadius: cornerRadius, perform: perform))
    }
}

private struct OrganisationDropModifier: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let perform: (DragPayload) -> Bool

    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .dropDestination(for: String.self) { items, _ in
                    guard let payload = items.lazy.compactMap({ DragPayload(text: $0) }).first else { return false }
                    return perform(payload)
                } isTargeted: { targeted in
                    isTargeted = targeted
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(ActionFill.primary, lineWidth: 3)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}
