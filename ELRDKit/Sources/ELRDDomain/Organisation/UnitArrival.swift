import Foundation

// Fahrzeugstatus (FMS) wurde auf Wunsch von Jonas wieder entfernt (E110);
// geblieben ist das erwartete Eintreffen (Schritt 92).

public extension MissionUnit {
    /// Eintreffen erwartet und noch nicht als „eingetroffen“ markiert.
    var isAwaitingArrival: Bool { expectedArrival != nil }

    /// Eintreffen überfällig (Schritt 92).
    func isArrivalOverdue(now: Date) -> Bool {
        guard let expectedArrival else { return false }
        return expectedArrival < now
    }
}
