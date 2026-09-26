import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MistralWidgetSnapshotTests {
    @Test(arguments: [
        (MenuBarMetricPreference.automatic, ["primary"]),
        (MenuBarMetricPreference.primary, ["primary"]),
        (MenuBarMetricPreference.monthlyPlan, ["mistral-monthly-plan"]),
    ])
    func `widget snapshot follows the Mistral metric for Monthly Plan rows`(
        preference: MenuBarMetricPreference,
        expectedIDs: [String]) async throws
    {
        let suite = "UsageStoreWidgetSnapshotTests-mistral-monthly-plan-\(preference.rawValue)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(preference, for: .mistral)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let planWindow = RateWindow(
            usedPercent: 40,
            windowMinutes: nil,
            resetsAt: Date().addingTimeInterval(5 * 24 * 60 * 60),
            resetDescription: "€102.00 / €255.00 · €153.00 left")
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                extraRateWindows: [
                    NamedRateWindow(id: "mistral-monthly-plan", title: "Monthly Plan", window: planWindow),
                ],
                updatedAt: Date()),
            provider: .mistral)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "mistral-monthly-plan-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .mistral })
        let rows = try #require(entry.usageRows)
        #expect(rows.map(\.id) == expectedIDs)
        let titles = ["primary": "Included API", "mistral-monthly-plan": "Monthly Plan"]
        let percents = ["primary": 90.0, "mistral-monthly-plan": 60.0]
        #expect(rows.map(\.title) == expectedIDs.compactMap { titles[$0] })
        #expect(rows.compactMap(\.percentLeft) == expectedIDs.compactMap { percents[$0] })
        // The plan row carries its window so widgets can show when the plan resets.
        #expect(rows.last?.window == (expectedIDs.last == "mistral-monthly-plan" ? planWindow : nil))
    }
}
