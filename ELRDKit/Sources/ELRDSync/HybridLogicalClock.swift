import Foundation
import ELRDDomain

/// Zeitstempel einer Hybrid-Logical-Clock (HLC).
///
/// Kombiniert die Uhrzeit des Geräts mit einem Zähler. So lassen sich Änderungen
/// verschiedener Geräte eindeutig und kausal korrekt ordnen, auch wenn die Uhren
/// leicht abweichen oder zwei Änderungen in derselben Millisekunde entstehen.
/// Bei völligem Gleichstand entscheidet die Geräte-ID – die Reihenfolge ist damit
/// auf allen Geräten identisch.
public struct HybridTimestamp: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// Millisekunden seit 1970.
    public let wallTime: Int64
    public let counter: Int
    public let deviceID: DeviceID

    public init(wallTime: Int64, counter: Int, deviceID: DeviceID) {
        self.wallTime = wallTime
        self.counter = max(counter, 0)
        self.deviceID = deviceID
    }

    public static func < (lhs: HybridTimestamp, rhs: HybridTimestamp) -> Bool {
        if lhs.wallTime != rhs.wallTime { return lhs.wallTime < rhs.wallTime }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID.rawValue.uuidString < rhs.deviceID.rawValue.uuidString
    }

    /// Zugehörige Uhrzeit (ohne Zähler).
    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(wallTime) / 1000)
    }

    public var description: String {
        "\(wallTime).\(counter)@\(deviceID.rawValue.uuidString.prefix(8))"
    }
}

/// Uhr eines Geräts nach dem HLC-Verfahren (Kulkarni et al., 2014).
public struct HybridLogicalClock: Sendable {
    public let deviceID: DeviceID
    public private(set) var last: HybridTimestamp?
    /// Wie weit ein fremder Zeitstempel höchstens vor der eigenen Uhr liegen darf.
    public let maximumDrift: TimeInterval

    public init(deviceID: DeviceID, last: HybridTimestamp? = nil, maximumDrift: TimeInterval = 3600) {
        self.deviceID = deviceID
        self.last = last
        self.maximumDrift = maximumDrift
    }

    /// Zeitstempel für eine lokale Änderung. Immer größer als alle bisherigen.
    public mutating func tick(now: Date) -> HybridTimestamp {
        let physical = Self.milliseconds(now)
        let next: HybridTimestamp
        if let last, last.wallTime >= physical {
            next = HybridTimestamp(wallTime: last.wallTime, counter: last.counter + 1, deviceID: deviceID)
        } else {
            next = HybridTimestamp(wallTime: physical, counter: 0, deviceID: deviceID)
        }
        last = next
        return next
    }

    /// Verarbeitet einen empfangenen Zeitstempel, damit spätere lokale Änderungen
    /// garantiert danach einsortiert werden.
    /// - Throws: `HybridClockError.remoteClockTooFarAhead`, wenn die fremde Uhr
    ///   offensichtlich falsch geht. Der Zeitstempel wird dann nicht übernommen.
    @discardableResult
    public mutating func receive(_ remote: HybridTimestamp, now: Date) throws -> HybridTimestamp {
        let physical = Self.milliseconds(now)
        let allowed = physical + Int64(maximumDrift * 1000)
        guard remote.wallTime <= allowed else {
            throw HybridClockError.remoteClockTooFarAhead(remote: remote.date, local: now)
        }
        let lastWall = last?.wallTime ?? Int64.min
        let lastCounter = last?.counter ?? 0
        let wall = max(lastWall, remote.wallTime, physical)

        let counter: Int
        if wall == lastWall && wall == remote.wallTime {
            counter = max(lastCounter, remote.counter) + 1
        } else if wall == lastWall {
            counter = lastCounter + 1
        } else if wall == remote.wallTime {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        let next = HybridTimestamp(wallTime: wall, counter: counter, deviceID: deviceID)
        last = next
        return next
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

public enum HybridClockError: Error, Equatable, Sendable {
    case remoteClockTooFarAhead(remote: Date, local: Date)
}
