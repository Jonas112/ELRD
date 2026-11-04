import Foundation
import ELRDDomain

/// Person, die als Einsatzleiter gewählt werden kann.
public struct PersonChoice: Identifiable, Hashable, Sendable {
    public let id: UserID
    public let name: String
    public let detail: String

    public init(id: UserID, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// Eingaben „Einsatzdaten“.
///
/// Gespeichert werden nur Felder, die hier tatsächlich geändert wurden. Hat in der
/// Zwischenzeit jemand anderes (anderes Fenster, später ein anderes Gerät) ein
/// anderes Feld geändert, bleibt dessen Änderung erhalten.
struct MissionEditForm: Equatable {
    var reason: String
    var type: MissionType?
    var location: String
    var dispatchNumber: String
    var startedAt: Date
    var endedAt: Date?
    /// Kilometerstände als Text, damit halbe Eingaben nicht verloren gehen.
    var odometerStart: String
    var odometerEnd: String
    var commanderID: UserID?

    private let original: Snapshot

    /// Vergleichswerte beim Öffnen.
    private struct Snapshot: Equatable {
        let reason: String
        let type: MissionType?
        let location: String
        let dispatchNumber: String
        let startedAt: Date
        let endedAt: Date?
        let odometerStart: Int?
        let odometerEnd: Int?
        let commanderID: UserID?
    }

    init(mission: Mission) {
        reason = mission.reason
        type = mission.type
        location = mission.location
        dispatchNumber = mission.dispatchNumber ?? ""
        startedAt = mission.startedAt
        endedAt = mission.endedAt
        odometerStart = mission.odometerStart.map(String.init) ?? ""
        odometerEnd = mission.odometerEnd.map(String.init) ?? ""
        commanderID = mission.commanderID
        original = Snapshot(
            reason: Self.trimmed(reason), type: type, location: Self.trimmed(location),
            dispatchNumber: Self.trimmed(dispatchNumber),
            startedAt: startedAt, endedAt: endedAt,
            odometerStart: mission.odometerStart, odometerEnd: mission.odometerEnd,
            commanderID: commanderID
        )
    }

    // MARK: Prüfung

    enum Problem: Equatable {
        case odometerNotANumber
        case mission(MissionIssue)

        var message: String {
            switch self {
            case .odometerNotANumber: "Kilometerstand bitte nur als ganze Zahl eingeben."
            case .mission(let issue): issue.description
            }
        }
    }

    static func parseKilometers(_ text: String) -> Int?? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: "")
        if digits.isEmpty { return .some(nil) }
        guard let value = Int(digits) else { return nil }
        return .some(value)
    }

    /// Probleme, wenn die Eingaben auf `mission` angewendet würden.
    func problems(applyingTo mission: Mission) -> [Problem] {
        guard Self.parseKilometers(odometerStart) != nil, Self.parseKilometers(odometerEnd) != nil else {
            return [.odometerNotANumber]
        }
        var candidate = mission
        apply(to: &candidate)
        return candidate.validate().map(Problem.mission)
    }

    // MARK: Übernehmen

    var hasChanges: Bool { current != original }

    private var current: Snapshot {
        Snapshot(
            reason: Self.trimmed(reason),
            type: type,
            location: Self.trimmed(location),
            dispatchNumber: Self.trimmed(dispatchNumber),
            startedAt: startedAt,
            endedAt: endedAt,
            odometerStart: Self.parseKilometers(odometerStart) ?? original.odometerStart,
            odometerEnd: Self.parseKilometers(odometerEnd) ?? original.odometerEnd,
            commanderID: commanderID
        )
    }

    /// Schreibt nur die geänderten Felder in `mission`.
    func apply(to mission: inout Mission) {
        let now = current
        if now.reason != original.reason { mission.reason = now.reason }
        if now.type != original.type { mission.type = now.type }
        if now.location != original.location { mission.location = now.location }
        if now.dispatchNumber != original.dispatchNumber {
            mission.dispatchNumber = now.dispatchNumber.isEmpty ? nil : now.dispatchNumber
        }
        if now.startedAt != original.startedAt { mission.startedAt = now.startedAt }
        if now.endedAt != original.endedAt { mission.endedAt = now.endedAt }
        if now.odometerStart != original.odometerStart { mission.odometerStart = now.odometerStart }
        if now.odometerEnd != original.odometerEnd { mission.odometerEnd = now.odometerEnd }
        if now.commanderID != original.commanderID { mission.commanderID = now.commanderID }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
