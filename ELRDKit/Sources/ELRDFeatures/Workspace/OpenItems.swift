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
        /// Lagemeldung an die ILS fällig (Schritt 69).
        case situationReportDue
        case notTriaged
        case urgentWithoutTransport
        /// SK 3 wartet zu lange ohne Transportmittel (Schritt 69).
        case longWait
        /// Klinik über ihrem Kontingent (Schritt 71).
        case hospitalOverloaded
        /// Nachsichtung fällig (Schritt 95).
        case retriageDue
        /// Erwartetes Eintreffen überschritten (Schritt 92).
        case arrivalOverdue
        /// Platzhalter seit langem ohne Fahrzeug (Schritt 69).
        case placeholderOverdue
        case placeholderUnits
        case unreadMessages

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Target: Equatable, Sendable {
        case section(WorkspaceSection)
        /// Direkt zum Patienten.
        case patient(PatientID)
        case messages
        case situationReport
        case hospitals
    }

    public let id: String
    public let kind: Kind
    /// SK-Abzeichen links, falls es um einen Patienten geht.
    public let triage: Sichtungskategorie?
    public let title: String
    public let detail: String
    public let actionTitle: String
    public let target: Target

    public static func items(for state: MissionState, now: Date, reminders: ReminderSettings = ReminderSettings()) -> [OpenItem] {
        var items: [OpenItem] = []
        let patients = Patient.sortedByNumber(state.patients)

        // Schritt 69: Lagemeldung im Takt (ab Einsatzbeginn bzw. letzter Lagemeldung).
        if reminders.situationReportMinutes > 0, !state.mission.isClosed {
            let last = state.lastSituationReportAt ?? state.mission.startedAt
            let since = minutes(since: last, now)
            if since >= reminders.situationReportMinutes {
                items.append(OpenItem(
                    id: "situationReport",
                    kind: .situationReportDue,
                    triage: nil,
                    title: "Lagemeldung an ILS fällig",
                    detail: state.lastSituationReportAt == nil ? "noch keine Lagemeldung, Einsatz läuft seit \(since) min" : "letzte vor \(since) min",
                    actionTitle: "Lagemeldung",
                    target: .situationReport
                ))
            }
        }

        let tooLong = reminders.transportWaitMinutes
        for patient in patients where patient.outcome == nil {
            // Ohne RTW/KTW/RTH gilt ein Patient als „ohne Transportmittel“, auch mit NEF (E66).
            let needsTransport = !patient.hasTransportUnit(in: state.units)
            let waited = minutes(since: patient.metadata.createdAt, now)
            let overdue = tooLong > 0 && waited >= tooLong
            let problem = overdue ? "wartet zu lange" : "hat kein Transportmittel"
            switch patient.triage {
            case .sk1 where needsTransport:
                items.append(patientItem(patient, .criticalWithoutTransport, problem, waiting(patient, now), "Einheit zuweisen"))
            case .sk2 where needsTransport:
                items.append(patientItem(patient, .urgentWithoutTransport, problem, waiting(patient, now), "Einheit zuweisen"))
            case .sk3 where needsTransport && overdue:
                items.append(patientItem(patient, .longWait, problem, waiting(patient, now), "Einheit zuweisen"))
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

        for load in HospitalDistribution.loads(state) where !load.overloadedTriages.isEmpty {
            let detail = load.overloadedTriages.map { triage in
                "\(triage.shortName) \(load.counts[triage] ?? 0) von \(load.quota?.limit(for: triage) ?? 0)"
            }
            items.append(OpenItem(
                id: "hospital-\(load.id)",
                kind: .hospitalOverloaded,
                triage: nil,
                title: "\(load.name) über Kontingent",
                detail: detail.joined(separator: ", "),
                actionTitle: "Kliniken",
                target: .hospitals
            ))
        }

        // Schritt 95: Nachsichtung je Kategorie nach Frist.
        if !state.mission.isClosed {
            for patient in patients where patient.outcome == nil {
                let limit = reminders.retriageMinutes(for: patient.triage)
                guard limit > 0, let last = patient.lastTriagedAt else { continue }
                let since = minutes(since: last, now)
                guard since >= limit else { continue }
                items.append(OpenItem(
                    id: "retriage-\(patient.id.rawValue.uuidString)",
                    kind: .retriageDue,
                    triage: patient.triage,
                    title: "\(patient.displayName) Nachsichtung fällig",
                    detail: "zuletzt gesichtet vor \(since) min (\(patient.triage.shortName))",
                    actionTitle: "Patient öffnen",
                    target: .patient(patient.id)
                ))
            }
        }

        // Schritt 92: Eintreffen überfällig (Platzhalter oder Status 3 mit erwarteter Zeit).
        for unit in state.activeUnits where unit.isArrivalOverdue(now: now) {
            guard let expected = unit.expectedArrival else { continue }
            items.append(OpenItem(
                id: "arrival-\(unit.id.rawValue.uuidString)",
                kind: .arrivalOverdue,
                triage: nil,
                title: "\(unit.displayName) noch nicht eingetroffen",
                detail: "erwartet \(expected.formatted(date: .omitted, time: .shortened)) Uhr, seit \(minutes(since: expected, now)) min überfällig – bei der ILS nachfragen",
                actionTitle: "Einheiten",
                target: .section(.organisation)
            ))
        }

        let placeholders = state.activeUnits.filter(\.isPlaceholder)
        // Mit erwarteter Zeit zählt diese (oben), nicht die Wartezeit seit Anforderung.
        let overdue = reminders.placeholderMinutes > 0
            ? placeholders.filter { !$0.isAwaitingArrival && minutes(since: $0.metadata.createdAt, now) >= reminders.placeholderMinutes }
            : []
        if let oldest = overdue.min(by: { $0.metadata.createdAt < $1.metadata.createdAt }) {
            items.append(OpenItem(
                id: "placeholdersOverdue",
                kind: .placeholderOverdue,
                triage: nil,
                title: overdue.count == 1 ? "1 Platzhalter seit \(minutes(since: oldest.metadata.createdAt, now)) min ohne Fahrzeug" : "\(overdue.count) Platzhalter lange ohne Fahrzeug",
                detail: "bei der ILS nachfragen – ältester seit \(minutes(since: oldest.metadata.createdAt, now)) min",
                actionTitle: "Fahrzeug eintragen",
                target: .section(.organisation)
            ))
        }
        let recent = placeholders.filter { unit in !overdue.contains { $0.id == unit.id } }
        if !recent.isEmpty {
            let placeholders = recent
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

