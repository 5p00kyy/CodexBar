import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct LimitResetNotificationTests {
    struct LimitResetPost: Equatable {
        let provider: UsageProvider
        let window: QuotaWarningWindow
        let accountDisplayName: String?
    }

    @MainActor
    final class NotifierSpy: SessionQuotaNotifying {
        private(set) var transitionPosts: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []
        private(set) var limitResetPosts: [LimitResetPost] = []

        func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
            self.transitionPosts.append((transition: transition, provider: provider))
        }

        func postQuotaWarning(
            event _: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {}

        func postLimitReset(provider: UsageProvider, window: QuotaWarningWindow, accountDisplayName: String?) {
            self.limitResetPosts.append(LimitResetPost(
                provider: provider,
                window: window,
                accountDisplayName: accountDisplayName))
        }
    }

    private static let accountEmail = "limit-reset-notice@example.com"
    private static let start = Date(timeIntervalSince1970: 1_784_600_000)

    @Test
    func `limit reset notifications default off and persist when enabled`() throws {
        let suite = "LimitResetNotificationTests-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = Self.makeSettings(defaults: defaults, suiteName: suite)

        #expect(settings.limitResetNotificationsEnabled == false)
        #expect(defaults.object(forKey: "limitResetNotificationsEnabled") == nil)

        settings.limitResetNotificationsEnabled = true

        #expect(defaults.bool(forKey: "limitResetNotificationsEnabled") == true)
        #expect(Self.makeSettings(defaults: defaults, suiteName: suite).limitResetNotificationsEnabled == true)
    }

    @Test
    func `weekly reset notice names provider window and account`() async {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.limitResetNotificationsEnabled = true

        await Self.record(store, sessionUsed: 20, weeklyUsed: 60, offset: 0)
        await Self.record(store, sessionUsed: 20, weeklyUsed: 0, offset: 60 * 60)

        #expect(notifier.limitResetPosts == [
            LimitResetPost(provider: .claude, window: .weekly, accountDisplayName: Self.accountEmail),
        ])
    }

    @Test
    func `session reset notice names the session window`() async {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.limitResetNotificationsEnabled = true

        await Self.record(store, sessionUsed: 65, weeklyUsed: 20, offset: 0)
        await Self.record(store, sessionUsed: 0, weeklyUsed: 20, offset: 60 * 60)

        #expect(notifier.limitResetPosts == [
            LimitResetPost(provider: .claude, window: .session, accountDisplayName: Self.accountEmail),
        ])
    }

    @Test
    func `reset notices stay silent when disabled`() async {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        let recorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: Self.accountEmail)
        defer { recorder.invalidate() }

        await Self.record(store, sessionUsed: 20, weeklyUsed: 60, offset: 0)
        await Self.record(store, sessionUsed: 20, weeklyUsed: 0, offset: 60 * 60)

        #expect(recorder.events.count == 1)
        #expect(notifier.limitResetPosts.isEmpty)
    }

    @Test
    func `hide personal info omits the account from reset notices`() async {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.limitResetNotificationsEnabled = true
        store.settings.hidePersonalInfo = true

        await Self.record(store, sessionUsed: 20, weeklyUsed: 60, offset: 0)
        await Self.record(store, sessionUsed: 20, weeklyUsed: 0, offset: 60 * 60)

        #expect(notifier.limitResetPosts == [
            LimitResetPost(provider: .claude, window: .weekly, accountDisplayName: nil),
        ])
    }

    @Test
    func `session restored notice covers the matching session reset notice`() async {
        let notifier = NotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.sessionQuotaNotificationsEnabled = true
        store.settings.limitResetNotificationsEnabled = true

        let depleted = Self.snapshot(sessionUsed: 100, weeklyUsed: 60, offset: 0)
        let reset = Self.snapshot(sessionUsed: 0, weeklyUsed: 0, offset: 60 * 60)
        store.handleSessionQuotaTransition(provider: .claude, snapshot: depleted)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: depleted, now: depleted.updatedAt)
        store.handleSessionQuotaTransition(provider: .claude, snapshot: reset)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: reset, now: reset.updatedAt)

        #expect(notifier.transitionPosts.map(\.transition) == [.depleted, .restored])
        #expect(notifier.limitResetPosts == [
            LimitResetPost(provider: .claude, window: .weekly, accountDisplayName: Self.accountEmail),
        ])
    }

    @Test
    func `session restored dedup expires after the interval`() {
        let restoredAt = Date(timeIntervalSince1970: 1_784_600_000)
        let interval = LimitResetNotificationLogic.sessionRestoredDedupInterval

        #expect(LimitResetNotificationLogic.suppressesSessionReset(restoredPostedAt: nil, now: restoredAt) == false)
        #expect(LimitResetNotificationLogic.suppressesSessionReset(
            restoredPostedAt: restoredAt,
            now: restoredAt.addingTimeInterval(interval - 1)))
        #expect(LimitResetNotificationLogic.suppressesSessionReset(
            restoredPostedAt: restoredAt,
            now: restoredAt.addingTimeInterval(interval)) == false)
    }

    @Test
    func `reset notice copy names provider and window`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let weekly = LimitResetNotificationLogic.notificationCopy(
                providerName: "Claude",
                window: .weekly,
                accountDisplayName: nil)
            #expect(weekly.title == "Claude weekly limit reset")
            #expect(weekly.body == "Fresh quota is available.")

            let session = LimitResetNotificationLogic.notificationCopy(
                providerName: "Codex",
                window: .session,
                accountDisplayName: "work@example.com")
            #expect(session.title == "Codex session limit reset")
            #expect(session.body == "Account work@example.com. Fresh quota is available.")
        }
    }

    @Test
    func `reset notice copy is localized for simplified Chinese`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let copy = LimitResetNotificationLogic.notificationCopy(
                providerName: "Claude",
                window: .weekly,
                accountDisplayName: nil)
            #expect(copy.title == "Claude 每周额度已重置")
        }
    }

    // MARK: - Helpers

    private static func makeSettings(defaults: UserDefaults, suiteName: String) -> SettingsStore {
        SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func makeStore(notifier: NotifierSpy) -> UsageStore {
        let suiteName = "LimitResetNotificationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite for tests")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = false
        settings.hidePersonalInfo = false
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: testPlanUtilizationHistoryStore(suiteName: suiteName),
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        return store
    }

    private static func snapshot(sessionUsed: Double, weeklyUsed: Double, offset: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: sessionUsed, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: weeklyUsed, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: self.start.addingTimeInterval(offset),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: self.accountEmail,
                accountOrganization: nil,
                loginMethod: "max"))
    }

    private static func record(
        _ store: UsageStore,
        sessionUsed: Double,
        weeklyUsed: Double,
        offset: TimeInterval) async
    {
        let snapshot = self.snapshot(sessionUsed: sessionUsed, weeklyUsed: weeklyUsed, offset: offset)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: snapshot, now: snapshot.updatedAt)
    }
}
