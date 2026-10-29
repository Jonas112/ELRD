import Foundation
import Observation

/// ELRDEntitlements – Freischaltungen.
///
/// Beantwortet nur „Ist Funktion X verfügbar?“. Woher die Antwort kommt
/// (Entwicklung, Testzeitraum, Abo über StoreKit 2 ab Schritt 51, später ggf.
/// Lizenz über das ELRD-Backend), bleibt hinter `EntitlementProvider` verborgen.
public enum ELRDEntitlementsModule {
    public static let name = "ELRDEntitlements"
}

/// Funktionen, die eine Freischaltung brauchen können.
/// Rohwerte sind stabil (Einstellungen, Analyse, Backend).
public enum Feature: String, CaseIterable, Codable, Sendable {
    /// Einsätze anlegen und bearbeiten.
    case missionEditing
    /// Einsätze ansehen (auch beendete).
    case missionViewing
    /// PDF-Berichte erzeugen und teilen.
    case reportExport
    /// Eigene Berichtsvorlagen anlegen.
    case customReportTemplates
    /// Mehrere Geräte im selben Einsatz (Mehrbenutzer-Modus).
    case multiDevice
    /// Abgleich mit dem ELRD-Backend.
    case backendSync

    public var displayName: String {
        switch self {
        case .missionEditing: "Einsätze bearbeiten"
        case .missionViewing: "Einsätze ansehen"
        case .reportExport: "Berichte exportieren"
        case .customReportTemplates: "Eigene Berichtsvorlagen"
        case .multiDevice: "Mehrere Geräte im Einsatz"
        case .backendSync: "ELRD-Backend"
        }
    }
}

/// Stand der Freischaltung.
public enum EntitlementState: Hashable, Sendable {
    /// Entwicklung, TestFlight-Builds, Vorschauen: alles frei.
    case development
    /// Testzeitraum läuft.
    case trial(endsAt: Date)
    /// Gültiges Abo.
    case subscribed(SubscriptionInfo)
    /// Kein gültiges Abo (Testzeitraum vorbei oder Abo abgelaufen).
    case expired(since: Date?)

    public var hasFullAccess: Bool {
        switch self {
        case .development, .trial, .subscribed: true
        case .expired: false
        }
    }

    /// Text für Einstellungen und Hinweise.
    public func summary(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .development:
            return "Alle Funktionen freigeschaltet (Entwicklung)"
        case let .trial(endsAt):
            let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: endsAt)).day ?? 0)
            return days == 1 ? "Testzeitraum: noch 1 Tag" : "Testzeitraum: noch \(days) Tage"
        case let .subscribed(info):
            if let expiresAt = info.expiresAt {
                let date = expiresAt.formatted(date: .numeric, time: .omitted)
                return info.willRenew ? "Abo aktiv, verlängert sich am \(date)" : "Abo aktiv bis \(date)"
            }
            return "Abo aktiv"
        case .expired:
            return "Kein aktives Abo – Einsätze können angesehen und exportiert werden"
        }
    }
}

/// Angaben zu einem gültigen Abo.
public struct SubscriptionInfo: Hashable, Codable, Sendable {
    public let productID: String
    public let expiresAt: Date?
    public let willRenew: Bool
    /// Zahlungsproblem, Apple gewährt eine Nachfrist – Funktionen bleiben frei.
    public let isInGracePeriod: Bool

    public init(productID: String, expiresAt: Date?, willRenew: Bool, isInGracePeriod: Bool = false) {
        self.productID = productID
        self.expiresAt = expiresAt
        self.willRenew = willRenew
        self.isInGracePeriod = isInGracePeriod
    }
}

/// Welche Funktionen in welchem Zustand verfügbar sind.
///
/// Grundsatz: Ohne Abo bleiben die eigenen Daten zugänglich – Einsätze ansehen
/// und als PDF exportieren geht immer (Datenschutz, Dokumentationspflicht).
/// Gesperrt wird das Anlegen und Bearbeiten. Endgültig festgelegt in Schritt 51.
public struct EntitlementPolicy: Sendable {
    public let alwaysAvailable: Set<Feature>

    public init(alwaysAvailable: Set<Feature>) {
        self.alwaysAvailable = alwaysAvailable
    }

    public static let standard = EntitlementPolicy(alwaysAvailable: [.missionViewing, .reportExport])

    public func isEnabled(_ feature: Feature, in state: EntitlementState) -> Bool {
        state.hasFullAccess || alwaysAvailable.contains(feature)
    }
}

/// Testzeitraum ab dem ersten App-Start.
public struct TrialPeriod: Hashable, Codable, Sendable {
    public let startedAt: Date
    public let length: TimeInterval

    /// 30 Tage wie in ELRDRG.
    public static let defaultLength: TimeInterval = 30 * 24 * 60 * 60

    public init(startedAt: Date, length: TimeInterval = TrialPeriod.defaultLength) {
        self.startedAt = startedAt
        self.length = max(length, 0)
    }

    public var endsAt: Date { startedAt.addingTimeInterval(length) }

    public func isActive(at date: Date) -> Bool { date >= startedAt && date < endsAt }
}

/// Ermittelt den Zustand aus Abo und Testzeitraum.
public enum EntitlementResolver {
    public static func resolve(subscription: SubscriptionInfo?, trial: TrialPeriod?, now: Date) -> EntitlementState {
        if let subscription {
            let stillValid = subscription.expiresAt.map { $0 > now } ?? true
            if stillValid || subscription.isInGracePeriod { return .subscribed(subscription) }
        }
        if let trial, trial.isActive(at: now) { return .trial(endsAt: trial.endsAt) }
        let since = [subscription?.expiresAt, trial?.endsAt].compactMap { $0 }.max()
        return .expired(since: since)
    }
}

// MARK: - Bereitsteller

/// Quelle der Freischaltungen. Oberfläche und `MissionStore` fragen nur hierüber.
@MainActor
public protocol EntitlementProvider: AnyObject {
    var state: EntitlementState { get }
    var policy: EntitlementPolicy { get }
    /// Aktualisiert den Zustand (z. B. nach Kauf, beim App-Start).
    func refresh() async
}

public extension EntitlementProvider {
    func isEnabled(_ feature: Feature) -> Bool {
        policy.isEnabled(feature, in: state)
    }
}

/// Fester Zustand – für Entwicklung, Vorschauen und Tests.
@MainActor
@Observable
public final class StaticEntitlements: EntitlementProvider {
    public var state: EntitlementState
    public let policy: EntitlementPolicy

    public init(state: EntitlementState = .development, policy: EntitlementPolicy = .standard) {
        self.state = state
        self.policy = policy
    }

    public func refresh() async {}

    /// Alles frei, solange das Abo noch nicht eingebaut ist (bis Schritt 51).
    public static func development() -> StaticEntitlements { StaticEntitlements() }
}

/// Fehler, wenn eine gesperrte Funktion benutzt werden soll.
public struct FeatureLockedError: Error, Equatable, Sendable, LocalizedError {
    public let feature: Feature

    public init(feature: Feature) {
        self.feature = feature
    }

    public var errorDescription: String? {
        "„\(feature.displayName)“ ist ohne aktives Abo nicht verfügbar."
    }
}
