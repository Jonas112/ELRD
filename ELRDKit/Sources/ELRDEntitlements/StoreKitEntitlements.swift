import Foundation
import Observation
import StoreKit

/// Freischaltung über StoreKit 2 (Schritt 51): Monatsabo wie in ELRDRG plus
/// Testzeitraum ab dem ersten Start. In Entwicklungs-Builds (`forceDevelopment`)
/// ist alles frei, Produkte und Kauf lassen sich trotzdem testen.
@MainActor
@Observable
public final class StoreKitEntitlements: EntitlementProvider {
    /// Produktkennung aus ELRDRG (App Store Connect).
    public static let productIDs: Set<String> = ["ELRD.RescueCommander.BasisFunctionsMonthly"]

    public private(set) var state: EntitlementState
    public let policy: EntitlementPolicy
    public private(set) var products: [Product] = []
    public private(set) var isPurchasing = false
    /// Letzter Fehler für die Oberfläche (deutsch).
    public var message: String?

    private let trial: TrialPeriod
    private let forceDevelopment: Bool
    @ObservationIgnored private var updates: Task<Void, Never>?

    public init(trial: TrialPeriod, policy: EntitlementPolicy = .standard, forceDevelopment: Bool) {
        self.trial = trial
        self.policy = policy
        self.forceDevelopment = forceDevelopment
        state = forceDevelopment ? .development : EntitlementResolver.resolve(subscription: nil, trial: trial, now: Date())
        updates = Task { [weak self] in
            for await _ in Transaction.updates {
                await self?.refresh()
            }
        }
    }

    /// Testzeitraum: Beginn wird beim ersten Start gespeichert.
    public static func storedTrial(defaults: UserDefaults = .standard, now: Date = Date()) -> TrialPeriod {
        let key = "entitlements.trialStartedAt"
        if let started = defaults.object(forKey: key) as? Date {
            return TrialPeriod(startedAt: started)
        }
        defaults.set(now, forKey: key)
        return TrialPeriod(startedAt: now)
    }

    public var trialEndsAt: Date { trial.endsAt }

    public func refresh() async {
        if products.isEmpty {
            products = (try? await Product.products(for: Self.productIDs)) ?? []
        }
        let subscription = await currentSubscription()
        state = forceDevelopment ? .development : EntitlementResolver.resolve(subscription: subscription, trial: trial, now: Date())
    }

    /// Kauf; `true`, wenn danach ein Abo besteht.
    @discardableResult
    public func purchase(_ product: Product) async -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = "Der Kauf ließ sich nicht prüfen. Bitte später erneut versuchen."
                    return false
                }
                await transaction.finish()
                await refresh()
                return true
            case .pending:
                message = "Der Kauf wartet auf Bestätigung (z. B. durch Familienfreigabe)."
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            message = "Kauf nicht möglich: \(error.localizedDescription)"
            return false
        }
    }

    /// „Käufe wiederherstellen“.
    public func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            message = "Wiederherstellen nicht möglich: \(error.localizedDescription)"
        }
        await refresh()
    }

    private func currentSubscription() async -> SubscriptionInfo? {
        var found: SubscriptionInfo?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            var willRenew = true
            var inGrace = false
            if let statuses = try? await products.first(where: { $0.id == transaction.productID })?.subscription?.status {
                for status in statuses {
                    if case .verified(let renewal) = status.renewalInfo { willRenew = renewal.willAutoRenew }
                    if status.state == .inGracePeriod || status.state == .inBillingRetryPeriod { inGrace = true }
                }
            }
            found = SubscriptionInfo(
                productID: transaction.productID,
                expiresAt: transaction.expirationDate,
                willRenew: willRenew,
                isInGracePeriod: inGrace
            )
        }
        return found
    }
}
