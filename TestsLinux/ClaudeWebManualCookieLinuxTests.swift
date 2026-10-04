import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Manual-cookie transport and routing without browser import or live credentials.
@Suite(.serialized)
struct ClaudeWebManualCookieLinuxTests {
    private static let manualHeader = "sessionKey=sk-ant-manual-token"

    @Test
    func `manual cookie exempts Claude web from the Linux browser gate`() {
        #if os(Linux)
        let manual = ProviderSettingsSnapshot.make(claude: .init(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .manual,
            manualCookieHeader: Self.manualHeader))

        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .claude, settings: manual))
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .claude, settings: manual))

        // No manual cookie: explicit web still needs the macOS-only browser import.
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .claude, settings: .make()))
        // Blank manual cookie does not count.
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .claude,
            settings: ProviderSettingsSnapshot.make(claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .manual,
                manualCookieHeader: "   "))))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `manual cookie fetch reads Claude usage on Linux`() async throws {
        #if os(Linux)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/organizations":
                return Self.json(
                    url,
                    #"[{"uuid":"org-123","name":"Test Org","capabilities":["chat"]}]"#)
            case "/api/organizations/org-123/usage":
                #expect(request.value(forHTTPHeaderField: "Cookie") == Self.manualHeader)
                return Self.json(
                    url,
                    #"{"five_hour":{"utilization":11},"seven_day":{"utilization":22}}"#)
            case "/api/account":
                return Self.json(
                    url,
                    #"{"email_address":"user@example.com","memberships":["#
                        + #"{"organization":{"uuid":"org-123","name":"Test Org","rate_limit_tier":"#
                        + #""default_claude_pro"}}]}"#)
            default:
                return Self.json(url, "{}", status: 404)
            }
        }

        let usage = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await ClaudeWebAPIFetcher.fetchUsage(
                cookieHeader: Self.manualHeader,
                includeUsageDetails: false,
                includePrepaidBalance: false)
        }

        #expect(usage.sessionPercentUsed == 11)
        #expect(usage.weeklyPercentUsed == 22)
        #expect(usage.accountOrganizationID == "org-123")
        #expect(usage.accountEmail == "user@example.com")
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `browser import stays unavailable on Linux`() {
        #if os(Linux)
        #expect(ClaudeWebAPIFetcher.hasSessionKey(browserDetection: BrowserDetection(cacheTTL: 0)) == false)
        #expect(ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: Self.manualHeader))
        #expect(!ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: "other=1"))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `auto planner makes web available only with a valid manual session`() async {
        #if os(Linux)
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        for header in [Self.manualHeader, "other=1", "   "] {
            let context = Self.context(sourceMode: .auto, cookieHeader: header)
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
            let web = strategies.first { $0.id == "claude.web" }
            #expect(web != nil)
            #expect(await web?.isAvailable(context) == (header == Self.manualHeader))
        }
        #endif
    }

    @Test
    func `explicit web uses the provider pipeline without a CLI fallback`() async throws {
        #if os(Linux)
        let context = Self.context(sourceMode: .web, cookieHeader: Self.manualHeader)
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Cookie") == Self.manualHeader)
            switch url.path {
            case "/api/organizations":
                return Self.json(url, #"[{"uuid":"org-123","capabilities":["chat"]}]"#)
            case "/api/organizations/org-123/usage":
                return Self.json(url, #"{"five_hour":{"utilization":11},"seven_day":{"utilization":22}}"#)
            case "/api/account":
                return Self.json(url, "{}")
            case "/api/organizations/org-123/overage_spend_limit":
                return Self.json(url, "{}", status: 404)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                return Self.json(url, "{}", status: 404)
            }
        }
        let outcome = await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            await descriptor.fetchOutcome(context: context)
        }
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web"])
        let result = try outcome.result.get()
        #expect(result.sourceLabel == "web")
        #expect(result.usage.primary?.usedPercent == 11)
        #expect(result.usage.secondary?.usedPercent == 22)
        #endif
    }

    @Test
    func `invalid manual cookie fails before issuing HTTP requests`() async {
        #if os(Linux)
        let transport = ProviderHTTPTransportHandler { request in
            Issue.record("Invalid cookie issued a request")
            return try Self.json(#require(request.url), "{}")
        }
        await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            do {
                _ = try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: "other=1")
                Issue.record("Invalid cookie unexpectedly returned usage")
            } catch ClaudeWebAPIFetcher.FetchError.noSessionKeyFound {
                // Expected validation failure.
            } catch {
                Issue.record("Unexpected validation error: \(error)")
            }
        }
        #endif
    }

    @Test
    func `Cloudflare challenge remains a terminal explicit web failure`() async {
        #if os(Linux)
        let context = Self.context(sourceMode: .web, cookieHeader: Self.manualHeader)
        let transport = ProviderHTTPTransportHandler { request in
            try Self.json(#require(request.url), "Just a moment", status: 403)
        }
        let outcome = await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            await ProviderDescriptorRegistry.descriptor(for: .claude).fetchOutcome(context: context)
        }
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true])
        if case let .failure(error) = outcome.result {
            #expect(error.localizedDescription.contains("Cloudflare"))
        } else {
            Issue.record("Cloudflare challenge unexpectedly returned usage")
        }
        #endif
    }

    #if os(Linux)
    private static func context(sourceMode: ProviderSourceMode, cookieHeader: String) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .manual,
                manualCookieHeader: cookieHeader)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: [:]),
            browserDetection: browserDetection)
    }

    private static func json(
        _ url: URL,
        _ body: String,
        status: Int = 200) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
    #endif
}
