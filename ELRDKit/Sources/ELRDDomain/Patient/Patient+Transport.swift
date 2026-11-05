import Foundation

extension Patient {
    /// Ob dem Patienten eine aktive Einheit zugeordnet ist, die Patienten
    /// transportieren darf (RTW, KTW, RTH; E66).
    public func hasTransportUnit(in units: [MissionUnit]) -> Bool {
        units.active.contains { unitIDs.contains($0.id) && $0.type.transportsPatients }
    }
}
