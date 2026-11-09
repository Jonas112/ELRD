import Foundation

/// Eine Änderung der Sichtungskategorie mit Zeitpunkt (Schritt 86).
public struct TriageChange: Codable, Hashable, Sendable {
    public let at: Date
    public let triage: Sichtungskategorie

    public init(at: Date, triage: Sichtungskategorie) {
        self.at = at
        self.triage = triage
    }
}

public extension Sichtungskategorie {
    /// Gesichtet = alles außer „ungesichtet“.
    var isTriaged: Bool { self != .ungesichtet }
}

public extension Patient {
    /// Sichtungsverlauf. Patienten von vor Schritt 86 haben keinen gespeicherten
    /// Verlauf – dann gilt: seit der Anlage in der heutigen Kategorie.
    var effectiveTriageHistory: [TriageChange] {
        if let triageHistory, !triageHistory.isEmpty { return triageHistory.sorted { $0.at < $1.at } }
        return [TriageChange(at: metadata.createdAt, triage: triage)]
    }

    /// Zeitpunkt der ersten Sichtung (erste Kategorie außer „ungesichtet“).
    var firstTriagedAt: Date? {
        effectiveTriageHistory.first { $0.triage.isTriaged }?.at
    }

    /// Kategorie zu einem Zeitpunkt (`nil` vor der Anlage).
    func triage(at date: Date) -> Sichtungskategorie? {
        guard metadata.createdAt <= date else { return nil }
        return effectiveTriageHistory.last { $0.at <= date }?.triage ?? effectiveTriageHistory.first?.triage
    }

    /// Letzte Sichtung oder Bestätigung (Schritt 95).
    var lastTriagedAt: Date? {
        effectiveTriageHistory.last { $0.triage.isTriaged }?.at
    }

    /// Nachsichtung: gleiche Kategorie erneut bestätigen (nur über Commands).
    mutating func confirmTriage(at date: Date) {
        var history = effectiveTriageHistory
        history.append(TriageChange(at: date, triage: triage))
        triageHistory = history
    }

    /// Kategorie ändern und im Verlauf festhalten (nur über Commands aufrufen).
    mutating func recordTriage(_ new: Sichtungskategorie, at date: Date) {
        var history = effectiveTriageHistory
        if history.last?.triage != new { history.append(TriageChange(at: date, triage: new)) }
        triageHistory = history
        triage = new
    }
}
