import Foundation

/// Ein Einsatz (eine Lage). Wurzel aller einsatzbezogenen Daten.
public struct Mission: VersionedEntity, MissionScoped {
    public let id: MissionID
    public var metadata: EntityMetadata

    /// Laufende Nummer im Kalenderjahr des Einsatzbeginns, beginnend bei 1.
    /// Wird beim Anlegen vergeben (`nextYearNumber`) und danach nicht mehr geändert.
    public let yearNumber: Int

    /// Einsatznummer der Leitstelle (ILS). Als Text, da Formate je Leitstelle abweichen.
    public var dispatchNumber: String?
    /// Einsatzgrund / Meldebild als Freitext.
    public var reason: String
    public var type: MissionType?
    /// Einsatzort als Freitext (Adresse, Ortsbeschreibung).
    public var location: String
    public var coordinate: GeoCoordinate?

    public var startedAt: Date
    public var endedAt: Date?
    /// Beendete Einsätze sind schreibgeschützt, können aber wieder geöffnet werden.
    public private(set) var isClosed: Bool

    /// Kilometerstand des Führungsfahrzeugs bei Beginn und Ende.
    public var odometerStart: Int?
    public var odometerEnd: Int?

    /// Einsatzleiter (lokaler Benutzer).
    public var commanderID: UserID?

    /// Lage in eigenen Worten (für die Lagemeldung, Schritt 67).
    public var situationNote: String?
    /// Gefahren an der Einsatzstelle (für die Lagemeldung).
    public var hazards: String?
    /// Aufnahmekontingente der Kliniken je SK (Schritt 71).
    public var hospitalQuotas: [HospitalQuota]?
    /// Führungsstruktur (Schritt 73).
    public var leadership: [LeadershipPosition]?
    /// Übungseinsatz (Schritt 88); `nil` = echter Einsatz (E95).
    public var isExercise: Bool?
    /// Teilnehmer im geteilten Einsatz mit Abschnitt und Rechten (Schritt 89).
    public var participants: [MissionParticipant]?
    /// Personenbezogene Patientendaten entfernt (Schritt 102); `nil` = noch nicht.
    public var anonymizedAt: Date?
    /// Nachbesprechung (Schritt 107).
    public var debrief: MissionDebrief?
    /// Abgehakte offene Punkte („zur Kenntnis genommen“, Schritt 96).
    public var acknowledgedItems: [AcknowledgedOpenItem]?
    /// Sonstige Stellen und benachbarte Kräfte für den Kommunikationsplan (Schritt 126).
    public var communicationContacts: [CommunicationContact]?
    /// Einlagen der Übungsleitung (Schritt 138); nur bei Übungen.
    public var exerciseInjects: [ExerciseInject]?
    /// Lernpfad-Einsatz (Schritt 139): Übung mit Anleitung Schritt für Schritt.
    public var isTutorial: Bool?

    public init(
        id: MissionID = MissionID(),
        metadata: EntityMetadata,
        yearNumber: Int,
        dispatchNumber: String? = nil,
        reason: String = "",
        type: MissionType? = nil,
        location: String = "",
        coordinate: GeoCoordinate? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        isClosed: Bool = false,
        odometerStart: Int? = nil,
        odometerEnd: Int? = nil,
        commanderID: UserID? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.yearNumber = max(yearNumber, 1)
        self.dispatchNumber = dispatchNumber
        self.reason = reason
        self.type = type
        self.location = location
        self.coordinate = coordinate
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isClosed = isClosed
        self.odometerStart = odometerStart
        self.odometerEnd = odometerEnd
        self.commanderID = commanderID
    }
}

// MARK: - Fachlogik

public extension Mission {
    /// Übung statt echter Einsatz (Schritt 88).
    var isExerciseMission: Bool { isExercise == true }

    /// Ein Einsatz gehört zu sich selbst (für einheitliche Behandlung in der Synchronisation).
    var missionID: MissionID { id }

    /// Titel für Listen: Einsatzgrund, sonst Einsatzart, sonst „Einsatz <Nummer>“.
    var title: String {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReason.isEmpty { return trimmedReason }
        if let type { return type.displayName }
        return "Einsatz \(yearNumber)"
    }

    /// Anzeige-Nummer „Jahr/Nummer“, z. B. „2026/12“.
    func displayNumber(calendar: Calendar = .current) -> String {
        "\(calendar.component(.year, from: startedAt))/\(yearNumber)"
    }

    /// Dauer bis Einsatzende bzw. bis `now`, wenn der Einsatz noch läuft.
    func duration(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Gefahrene Kilometer, falls beide Stände plausibel erfasst sind.
    var distanceDriven: Int? {
        guard let odometerStart, let odometerEnd, odometerEnd >= odometerStart else { return nil }
        return odometerEnd - odometerStart
    }

    /// Beendet den Einsatz. Ein bereits gesetztes Einsatzende bleibt erhalten.
    mutating func close(at date: Date) {
        if endedAt == nil { endedAt = max(date, startedAt) }
        isClosed = true
    }

    /// Öffnet einen beendeten Einsatz wieder. Das Einsatzende bleibt wie in ELRDRG
    /// erhalten und kann bei Bedarf manuell geändert werden.
    mutating func reopen() {
        isClosed = false
    }

    /// Fachliche Prüfung. Leeres Ergebnis bedeutet: gültig.
    func validate() -> [MissionIssue] {
        var issues: [MissionIssue] = []
        if let endedAt, endedAt < startedAt { issues.append(.endBeforeStart) }
        if let odometerStart, odometerStart < 0 { issues.append(.negativeOdometer) }
        if let odometerEnd, odometerEnd < 0 { issues.append(.negativeOdometer) }
        if let odometerStart, let odometerEnd, odometerEnd < odometerStart {
            issues.append(.odometerEndBeforeStart)
        }
        return issues
    }

    /// Nächste freie Jahresnummer für einen Einsatz, der am `startDate` beginnt.
    /// Gelöschte Einsätze werden mitgezählt, damit Nummern nicht doppelt vergeben werden.
    static func nextYearNumber(
        startingAt startDate: Date,
        existing missions: some Sequence<Mission>,
        calendar: Calendar = .current
    ) -> Int {
        let year = calendar.component(.year, from: startDate)
        let highest = missions
            .filter { calendar.component(.year, from: $0.startedAt) == year }
            .map(\.yearNumber)
            .max() ?? 0
        return highest + 1
    }
}

/// Fachliche Fehler eines Einsatzes.
public enum MissionIssue: Hashable, Sendable, CustomStringConvertible {
    case endBeforeStart
    case negativeOdometer
    case odometerEndBeforeStart

    public var description: String {
        switch self {
        case .endBeforeStart: "Das Einsatzende liegt vor dem Einsatzbeginn."
        case .negativeOdometer: "Der Kilometerstand darf nicht negativ sein."
        case .odometerEndBeforeStart: "Der Kilometerstand bei Ende ist kleiner als bei Beginn."
        }
    }
}
