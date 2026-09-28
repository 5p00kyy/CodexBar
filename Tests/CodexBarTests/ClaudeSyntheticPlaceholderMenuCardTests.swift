import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct ClaudeSyntheticPlaceholderMenuCardTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `synthetic session is unavailable instead of 100 percent remaining`() throws {
        let model = try Self.model(
            snapshot: UsageSnapshot(
                primary: Self.syntheticSession,
                secondary: nil,
                updatedAt: Self.now))

        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == "Limits not available")
        #expect(model.usageNotes == ["Session usage unavailable for this account."])
        #expect(UsageLimitsAvailability.resolve(
            provider: .claude,
            snapshot: UsageSnapshot(primary: Self.syntheticSession, secondary: nil, updatedAt: Self.now)) ==
            .unavailable)
    }

    @Test
    func `real weekly usage remains visible beside an unavailable session`() throws {
        let weekly = RateWindow(
            usedPercent: 42,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Self.now.addingTimeInterval(3600),
            resetDescription: nil)
        let model = try Self.model(
            snapshot: UsageSnapshot(
                primary: Self.syntheticSession,
                secondary: weekly,
                updatedAt: Self.now))

        #expect(model.metrics.map(\.id) == ["secondary"])
        #expect(model.usageNotes == ["Session usage unavailable for this account."])
        #expect(UsageLimitsAvailability.resolve(
            provider: .claude,
            snapshot: UsageSnapshot(primary: Self.syntheticSession, secondary: weekly, updatedAt: Self.now)) ==
            .available)
    }

    @Test
    func `real zero usage is not treated as unavailable`() throws {
        let primary = RateWindow(
            usedPercent: 0,
            windowMinutes: 5 * 60,
            resetsAt: Self.now.addingTimeInterval(3600),
            resetDescription: nil)
        let model = try Self.model(
            snapshot: UsageSnapshot(primary: primary, secondary: nil, updatedAt: Self.now))

        #expect(model.metrics.map(\.id) == ["primary"])
        #expect(model.usageNotes.isEmpty)
        #expect(UsageLimitsAvailability.resolve(
            provider: .claude,
            snapshot: UsageSnapshot(primary: primary, secondary: nil, updatedAt: Self.now)) == .available)
    }

    private static var syntheticSession: RateWindow {
        RateWindow(
            usedPercent: 0,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
    }

    private static func model(snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            limitsAvailability: UsageLimitsAvailability.resolve(provider: .claude, snapshot: snapshot),
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: self.now))
    }
}

@MainActor
struct ClaudeSyntheticPlaceholderDisplayTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `synthetic session is absent from compact menu and plain CLI output`() {
        let settings = testSettingsStore(suiteName: "ClaudeSyntheticPlaceholderDisplayTests")
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: nil,
            updatedAt: Self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "claude@example.com",
                accountOrganization: nil,
                loginMethod: "web"))
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let descriptor = MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let menuLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }
        #expect(!menuLines.contains(where: { $0.contains("100% left") }))
        #expect(menuLines.contains("Limits not available"))

        let cli = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: Self.now)
        #expect(!cli.contains("100% left"))
        #expect(cli.contains("Limits: not available"))
    }
}
