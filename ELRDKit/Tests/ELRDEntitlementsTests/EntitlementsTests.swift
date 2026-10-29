import Foundation
import Testing
@testable import ELRDEntitlements

private let now = Date(timeIntervalSince1970: 1_792_000_000)
private let day: TimeInterval = 24 * 60 * 60

@Suite("Freischaltungen")
struct EntitlementTests {
    @Test func trialPeriod() {
        let trial = TrialPeriod(startedAt: now)
        #expect(trial.endsAt == now.addingTimeInterval(30 * day))
        #expect(trial.isActive(at: now))
        #expect(trial.isActive(at: now.addingTimeInterval(30 * day - 1)))
        #expect(!trial.isActive(at: now.addingTimeInterval(30 * day)))
        #expect(!trial.isActive(at: now.addingTimeInterval(-1)), "Zurückgestellte Uhr verlängert nichts")
    }

    @Test func subscriptionWinsOverTrial() {
        let subscription = SubscriptionInfo(productID: "monthly", expiresAt: now.addingTimeInterval(10 * day), willRenew: true)
        let state = EntitlementResolver.resolve(subscription: subscription, trial: TrialPeriod(startedAt: now), now: now)
        #expect(state == .subscribed(subscription))
    }

    @Test func trialWhenNoSubscription() {
        let trial = TrialPeriod(startedAt: now.addingTimeInterval(-5 * day))
        #expect(EntitlementResolver.resolve(subscription: nil, trial: trial, now: now) == .trial(endsAt: trial.endsAt))
    }

    @Test func expiredSubscriptionAndTrial() {
        let subscription = SubscriptionInfo(productID: "monthly", expiresAt: now.addingTimeInterval(-2 * day), willRenew: false)
        let trial = TrialPeriod(startedAt: now.addingTimeInterval(-40 * day))
        let state = EntitlementResolver.resolve(subscription: subscription, trial: trial, now: now)
        #expect(state == .expired(since: now.addingTimeInterval(-2 * day)))
        #expect(!state.hasFullAccess)
        #expect(EntitlementResolver.resolve(subscription: nil, trial: nil, now: now) == .expired(since: nil))
    }

    @Test func gracePeriodKeepsAccess() {
        let subscription = SubscriptionInfo(productID: "monthly", expiresAt: now.addingTimeInterval(-day), willRenew: true, isInGracePeriod: true)
        #expect(EntitlementResolver.resolve(subscription: subscription, trial: nil, now: now).hasFullAccess)
    }

    @Test func policyKeepsOwnDataAccessible() {
        let policy = EntitlementPolicy.standard
        let expired = EntitlementState.expired(since: now)
        #expect(policy.isEnabled(.missionViewing, in: expired))
        #expect(policy.isEnabled(.reportExport, in: expired))
        #expect(!policy.isEnabled(.missionEditing, in: expired))
        #expect(!policy.isEnabled(.multiDevice, in: expired))
        for feature in Feature.allCases {
            #expect(policy.isEnabled(feature, in: .development))
            #expect(policy.isEnabled(feature, in: .trial(endsAt: now)))
        }
    }

    @Test func summaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        #expect(EntitlementState.trial(endsAt: now.addingTimeInterval(3 * day)).summary(now: now, calendar: calendar) == "Testzeitraum: noch 3 Tage")
        #expect(EntitlementState.trial(endsAt: now.addingTimeInterval(day)).summary(now: now, calendar: calendar) == "Testzeitraum: noch 1 Tag")
        #expect(EntitlementState.expired(since: nil).summary(now: now).contains("angesehen und exportiert"))
    }

    @Test @MainActor func staticProviderAndLockedError() {
        let provider = StaticEntitlements()
        #expect(provider.isEnabled(.missionEditing))
        provider.state = .expired(since: now)
        #expect(!provider.isEnabled(.missionEditing))
        #expect(provider.isEnabled(.reportExport))
        #expect(FeatureLockedError(feature: .missionEditing).localizedDescription == "„Einsätze bearbeiten“ ist ohne aktives Abo nicht verfügbar.")
    }
}
