import Foundation

/// Fahrzeugstatus nach FMS (Schritt 91), wie im bayerischen Rettungsdienst üblich.
/// Rohwerte = Statusziffer; nicht ändern (Teil des Speicherformats).
public enum UnitStatus: Int, Codable, Sendable, CaseIterable, Identifiable, DisplayNamed {
    case availableRadio = 1
    case availableStation = 2
    case enRoute = 3
    case onScene = 4
    case speakRequest = 5
    case unavailable = 6
    case patientOnBoard = 7
    case atDestination = 8

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .availableRadio: "Einsatzbereit über Funk"
        case .availableStation: "Einsatzbereit auf Wache"
        case .enRoute: "Einsatz übernommen / Anfahrt"
        case .onScene: "Am Einsatzort"
        case .speakRequest: "Sprechwunsch"
        case .unavailable: "Nicht einsatzbereit"
        case .patientOnBoard: "Patient aufgenommen"
        case .atDestination: "Am Transportziel"
        }
    }

    /// „S 4“
    public var shortName: String { "S \(rawValue)" }

    /// Vor Ort verfügbar (für Anzeige und Eintreffen).
    public var hasArrived: Bool { [.onScene, .patientOnBoard, .atDestination].contains(self) }
}

public extension MissionUnit {
    var status: UnitStatus? { statusCode.flatMap(UnitStatus.init(rawValue:)) }

    /// Erwartetes Eintreffen noch offen (Platzhalter oder Status 3 „Anfahrt“).
    var isAwaitingArrival: Bool {
        guard expectedArrival != nil else { return false }
        if let status, status.hasArrived || status == .unavailable { return false }
        // Echte Einheit ohne Status gilt als da (Eintragen heißt meist: vor Ort).
        return isPlaceholder || status == .enRoute
    }

    /// Eintreffen überfällig (Schritt 92).
    func isArrivalOverdue(now: Date) -> Bool {
        guard isAwaitingArrival, let expectedArrival else { return false }
        return expectedArrival < now
    }
}

/// Fahrzeuge je Status für die Lage (Schritt 96).
public struct UnitStatusSummary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let status: UnitStatus
        public let count: Int
    }

    public let entries: [Entry]
    /// Einheiten ohne Status (nicht Platzhalter).
    public let unknown: Int

    public init(units: [MissionUnit]) {
        let real = units.filter { !$0.metadata.isDeleted && !$0.isPlaceholder }
        entries = UnitStatus.allCases.compactMap { status in
            let count = real.filter { $0.status == status }.count
            return count > 0 ? Entry(status: status, count: count) : nil
        }
        unknown = real.filter { $0.status == nil }.count
    }
}
