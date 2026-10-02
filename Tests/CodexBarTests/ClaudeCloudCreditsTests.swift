import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct ClaudeCloudCreditsTests {
    private static let now = Date(timeIntervalSince1970: 1_790_812_800)
    /// Shape attributed to Pane's cloud_credits_live_shape_shows_the_remaining_dollars test:
    /// https://github.com/ItsJazii/pane/blob/beb4bbfd4e7c776d970a56d254e8cce4d61154d9/
    /// src-tauri/src/providers/claude.rs#L1049. This is not a live account capture by CodexBar.
    private static let funded = #"""
    {"limit_dollars":100,"used_dollars":25,"remaining_dollars":75,
     "utilization":25,"resets_at":"2026-11-05T07:59:00+00:00","locked_reason":null}
    """#

    @Test(arguments: [100.0, 250.0], ["pro", "max"])
    func `OAuth and Web retain dollar credits independently of plan labels`(limit: Double, plan: String) throws {
        let block = #"{"limit_dollars":\#(limit),"remaining_dollars":\#(limit),"locked_reason":null}"#
        let data = Self.usageData(block)
        let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data, subscriptionType: plan)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        let credit = try #require(oauth.cloudCredits)
        #expect(credit == web.cloudCredits)
        #expect(credit.limitDollars == limit)
        #expect(credit.remainingDollars == limit)
        #expect(credit.usedDollars == 0)
        #expect(credit.expiresAt == nil)
        #expect(oauth.primary.usedPercent == 12)
        #expect(oauth.providerCost?.used == 5)
        #expect(oauth.providerCost?.limit == 20)
    }

    @Test
    func `remaining dollars take precedence and used dollars provide a fallback`() throws {
        let reported = try Self.parse(#"{"limit_dollars":100,"used_dollars":10,"remaining_dollars":75}"#)
        #expect(reported.remainingDollars == 75)
        #expect(reported.usedDollars == 25)
        let derived = try Self.parse(#"{"limit_dollars":100,"used_dollars":25}"#)
        #expect(derived == reported)
    }

    @Test(arguments: [
        "null", "{}", "[]", "42",
        #"{"limit_dollars":null,"remaining_dollars":null}"#,
        #"{"limit_dollars":0,"remaining_dollars":0}"#,
        #"{"limit_dollars":-100,"remaining_dollars":10}"#,
        #"{"limit_dollars":100,"remaining_dollars":-1}"#,
        #"{"limit_dollars":100,"remaining_dollars":101}"#,
        #"{"limit_dollars":100,"used_dollars":101}"#,
        #"{"limit_dollars":100,"used_dollars":-1,"remaining_dollars":75}"#,
        #"{"limit_dollars":100,"utilization":25}"#,
        #"{"limit_dollars":"100","remaining_dollars":75}"#,
        #"{"limit_dollars":true,"remaining_dollars":0}"#,
        #"{"limit_dollars":100,"remaining_dollars":false}"#,
        #"{"limit_dollars":100,"remaining_dollars":75,"resets_at":"not-a-date"}"#,
        #"{"limit_dollars":100,"remaining_dollars":75,"locked_reason":false}"#,
    ])
    func `malformed optional credits cannot fail normal quotas`(block: String) throws {
        let data = Self.usageData(block)
        let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(oauth.cloudCredits == nil)
        #expect(web.cloudCredits == nil)
        #expect(oauth.primary.usedPercent == 12)
        #expect(web.sessionPercentUsed == 12)
    }

    @Test
    func `nonfinite dollars are rejected`() {
        #expect(ClaudeCloudCreditsSnapshot.parse(["limit_dollars": Double.infinity, "remaining_dollars": 75]) == nil)
        #expect(ClaudeCloudCreditsSnapshot.parse(["limit_dollars": 100, "remaining_dollars": Double.nan]) == nil)
    }

    @Test
    func `empty balance is exhausted while locked and expired balances are unavailable`() throws {
        let exhausted = try Self.parse(#"{"limit_dollars":100,"remaining_dollars":0}"#)
        let row = try #require(exhausted.detailSections(now: Self.now).first?.rows.first)
        #expect(row.value == "$0.00 of $100.00 remaining")
        #expect(row.progress?.usedPercent == 100)
        #expect(row.usageValue == 0)

        let locked = try Self.parse(#"{"limit_dollars":100,"remaining_dollars":75,"locked_reason":"internal_reason"}"#)
        let lockedRow = try #require(locked.detailSections(now: Self.now).first?.rows.first)
        #expect(lockedRow.value == "Unavailable")
        #expect(lockedRow.progress == nil)
        #expect(lockedRow.usageValue == nil)
        let lockedData = try JSONEncoder().encode(locked.detailSections(now: Self.now))
        let lockedJSON = try #require(String(bytes: lockedData, encoding: .utf8))
        #expect(!lockedJSON.contains("internal_reason"))

        let funded = try Self.parse(Self.funded)
        let expiry = try #require(funded.expiresAt)
        let expiredRow = try #require(funded.detailSections(now: expiry).first?.rows.first)
        #expect(expiredRow.value == "Expired")
        #expect(expiredRow.progress == nil)
        #expect(expiredRow.usageValue == nil)
        #expect(expiredRow.secondaryValue == "Expired 2026-11-05T07:59:00Z")
    }

    @Test
    func `web fetch carries credits without an extra credit endpoint`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/api/organizations":
                body = #"[{"uuid":"org-fixture","name":"Personal","capabilities":["chat"]}]"#
            case "/api/organizations/org-fixture/usage":
                body = try #require(String(bytes: Self.usageData(Self.funded), encoding: .utf8))
            case "/api/account":
                body = "{}"
            default:
                Issue.record("Unexpected endpoint: \(url.path)")
                body = "{}"
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: [:])))
        }
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            dataSource: .web,
            manualCookieHeader: "sessionKey=sk-ant-fixture-token",
            includePrepaidBalance: false)
        let usage = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await fetcher.loadLatestUsage()
        }
        #expect(try usage.cloudCredits == (Self.parse(Self.funded)))
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.details.first?.title == "Cloud credits")
        #expect(snapshot.providerCost?.used == 5)
    }

    @Test
    func `enrichment preserves original credits and does not populate an account without them`() throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Self.usageData(Self.funded))
        let cost = ProviderCostSnapshot(
            used: 5, limit: 20, currencyCode: "USD", period: "Monthly cap", balance: 30, updatedAt: Self.now)
        let enriched = usage.replacingWebExtras(extraRateWindows: [], providerCost: cost)
        #expect(enriched.cloudCredits == usage.cloudCredits)
        #expect(enriched.providerCost?.balance == 30)
        #expect(enriched.providerCost?.used == 5)
        let identified = enriched.withAccountIdentity("fixture-owner")
        #expect(identified.cloudCredits == usage.cloudCredits)
        #expect(identified.accountID == "fixture-owner")
        let fresh = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Self.usageData(nil))
        let other = fresh.replacingWebExtras(extraRateWindows: [], providerCost: cost)
        #expect(other.cloudCredits == nil)
        #expect(ClaudeOAuthFetchStrategy._snapshotForTesting(from: other).details.isEmpty)
    }

    @Test
    func `CLI text JSON and cached details preserve separate dollar credits and absolute expiry`() throws {
        let snapshot = try Self.snapshot()
        let text = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "Claude (oauth)", status: nil, useColor: false, resetStyle: .countdown),
            now: Self.now)
        #expect(text.contains("Cloud credits"))
        #expect(text.contains("$75.00 of $100.00 remaining"))
        #expect(text.contains("Expires 2026-11-05T07:59:00Z"))
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(restored.details == snapshot.details)
        let row = try #require(restored.details.first?.rows.first)
        #expect(row.progress?.used == 25)
        #expect(row.progress?.total == 100)
        #expect(row.usageValue == 75)
        #expect(restored.providerCost?.limit == 20)
        #expect(restored.providerCost?.used == 5)
        let legacy = try JSONDecoder().decode(
            UsageSnapshot.self, from: Data(#"{"primary":{"usedPercent":12},"updatedAt":0}"#.utf8))
        #expect(legacy.details.isEmpty)
    }

    @Test(arguments: [true, false])
    func `optional usage controls CLI publication and menu visibility`(showOptional: Bool) throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Self.usageData(Self.funded))
        let output = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage, includeOptionalUsage: showOptional)
        #expect(output.details.isEmpty == !showOptional)
        let model = try Self.menuModel(snapshot: Self.snapshot(), showOptional: showOptional)
        #expect(model.providerDetails.contains { $0.title == "Cloud credits" } == showOptional)
        if showOptional {
            let row = try #require(model.providerDetails.first?.rows.first)
            #expect(row.value == "$75.00 of $100.00 remaining")
            #expect(row.progress?.usedPercent == 25)
        }
    }

    private static func parse(_ block: String) throws -> ClaudeCloudCreditsSnapshot {
        try JSONDecoder().decode(ClaudeCloudCreditsSnapshot.self, from: Data(block.utf8))
    }

    private static func usageData(_ block: String?) -> Data {
        let field = block.map { #", "iguana_necktie": \#($0)"# } ?? ""
        return Data(#"""
        {"five_hour":{"utilization":12},"seven_day":{"utilization":34},
         "extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":500}\#(field)}
        """#.utf8)
    }

    private static func snapshot() throws -> UsageSnapshot {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Self.usageData(Self.funded))
        return ClaudeOAuthFetchStrategy._snapshotForTesting(from: ClaudeUsageSnapshot(
            primary: usage.primary,
            secondary: usage.secondary,
            opus: usage.opus,
            providerCost: usage.providerCost,
            cloudCredits: usage.cloudCredits,
            updatedAt: Self.now,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Pro",
            rawText: nil))
    }

    private static func menuModel(snapshot: UsageSnapshot, showOptional: Bool) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptional,
            hidePersonalInfo: false,
            usesLiveSubtitle: false,
            now: self.now))
    }
}
