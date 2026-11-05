import Foundation
import ELRDDomain
import ELRDStore

/// Ein offener Punkt in der Lage: etwas, das jetzt jemand erledigen sollte.
///
/// Die Lage zeigt keine bloßen Zahlen, sondern das Dringendste zuerst –
/// mit einem Knopf, der direkt dorthin führt.
public struct OpenItem: Identifiable, Equatable, Sendable {
    public enum Kind: Int, Comparable, Sendable {
        // Reihenfolge = Dringlichkeit.
        case criticalWithoutTransport
        case criticalNotRegistered
        case notTriaged
        case urgentWithoutTransport
        case placeholderUnits
        case unreadMessages

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Target: Equatable, Sendable {
        case section(WorkspaceSection)
        /// Direkt zum Patienten.
        case patient(PatientID)
        case messages
    }

    public let id: String
    public let kind: Kind
    /// SK-Abzeichen links, falls es um einen Patienten geht.
    public let triage: Sichtungskategorie?
    public let title: String
    public let detail: String
    public let actionTitle: String
    public let target: Target

    public static func items(for state: MissionState, now: Date) -> [OpenItem] {
        var items: [OpenItem] = []
        let patients = Patient.sortedByNumber(state.patients)

        for patient in patients where patient.outcome == nil {
            // Ohne RTW/KTW/RTH gilt ein Patient als „ohne Transportmittel“, auch mit NEF (E66).
            let needsTransport = !patient.hasTransportUnit(in: state.units)
            switch patient.triage {
            case .sk1 where needsTransport:
                items.append(patientItem(patient, .criticalWithoutTransport, "hat kein Transportmittel", waiting(patient, now), "Einheit zuweisen"))
            case .sk2 where needsTransport:
                items.append(patientItem(patient, .urgentWithoutTransport, "hat kein Transportmittel", waiting(patient, now), "Einheit zuweisen"))
            case .ungesichtet where patient.status == .waiting:
                items.append(patientItem(patient, .notTriaged, "noch nicht gesichtet", "angelegt vor \(minutes(since: patient.metadata.createdAt, now)) min", "Sichten"))
            default:
                break
            }
        }
        for patient in patients where patient.triage == .sk1 && patient.status != .released {
            if let destination = patient.destination, patient.registrationState != .angemeldet {
                items.append(patientItem(
                    patient, .criticalNotRegistered, "an Klinik noch nicht angemeldet",
                    "\(destination.name) · \(patient.registrationState.displayName)", "Anmelden"
                ))
            }
        }

        let placeholders = state.activeUnits.filter(\.isPlaceholder)
        if !placeholders.isEmpty {
            let summary = Dictionary(grouping: placeholders, by: \.type)
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.value.count) \($0.key.shortName)" }
                .joined(separator: ", ")
            items.append(OpenItem(
                id: "placeholders",
                kind: .placeholderUnits,
                triage: nil,
                title: placeholders.count == 1 ? "1 Platzhalter ohne Fahrzeug" : "\(placeholders.count) Platzhalter ohne Fahrzeug",
                detail: summary,
                actionTitle: "Fahrzeug eintragen",
                target: .section(.organisation)
            ))
        }

        let unread = state.unreadMessageCount
        if unread > 0 {
            items.append(OpenItem(
                id: "messages",
                kind: .unreadMessages,
                triage: nil,
                title: unread == 1 ? "1 Nachricht nicht gelesen" : "\(unread) Nachrichten nicht gelesen",
                detail: "Nachrichten",
                actionTitle: "Lesen",
                target: .messages
            ))
        }

        // Stabil sortieren: erst Dringlichkeit, innerhalb gleicher Art die Patientenreihenfolge.
        return items.enumerated()
            .sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }
            .map(\.element)
    }

    private static func patientItem(
        _ patient: Patient,
        _ kind: Kind,
        _ problem: String,
        _ detail: String,
        _ action: String
    ) -> OpenItem {
        OpenItem(
            id: "\(kind.rawValue)-\(patient.id.rawValue.uuidString)",
            kind: kind,
            triage: patient.triage,
            title: "\(patient.displayName) \(problem)",
            detail: detail,
            actionTitle: action,
            target: .patient(patient.id)
        )
    }

    private static func waiting(_ patient: Patient, _ now: Date) -> String {
        "wartet seit \(minutes(since: patient.metadata.createdAt, now)) min"
    }

    private static func minutes(since date: Date, _ now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 60))
    }
}

/// Patienten nach Versorgungsstand für die Lage.
public struct PatientStatusCounts: Equatable, Sendable {
    public let waiting: Int
    public let assigned: Int
    public let inTransport: Int
    public let released: Int

    public init(patients: [Patient]) {
        let active = patients.active
        waiting = active.filter { $0.status == .waiting }.count
        assigned = active.filter { $0.status == .assigned }.count
        inTransport = active.filter { $0.status == .inTransport }.count
        released = active.filter { $0.status == .released }.count
    }
}
