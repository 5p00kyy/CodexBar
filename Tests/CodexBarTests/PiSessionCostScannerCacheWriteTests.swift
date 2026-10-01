import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostScannerCacheWriteTests {
    @Test
    func `pi scanner prices recorded one-hour cache writes at two-times input`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)

        let claudeEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "api": "anthropic-messages",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 80,
                    "output": 20,
                    "cacheRead": 4,
                    "cacheWrite": 100,
                    "cacheWrite1h": 40,
                    "totalTokens": 204,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-09-30T10-00-00-000Z_cache-1h.jsonl",
            contents: env.jsonl([claudeEntry]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        let expectedCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 80,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 100,
            cacheCreationInputTokens1h: 40,
            outputTokens: 20,
            pricingDate: day,
            modelsDevCacheRoot: env.cacheRoot)
        // All writes at the 5-minute rate would underprice the recorded 1h subset.
        let unsplitCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 80,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 100,
            outputTokens: 20,
            pricingDate: day,
            modelsDevCacheRoot: env.cacheRoot)
        let expected = try #require(expectedCost)
        let unsplit = try #require(unsplitCost)
        #expect(expected - unsplit > 0.000001)
        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 204)
        let actual = try #require(report.data.first?.costUSD)
        #expect(abs(actual - expected) < 0.000001)
    }

    @Test
    func `pi scanner prices omp cttl one-hour cache writes at two-times input`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)

        let ompSessionsRoot = env.root.appendingPathComponent("omp-sessions", isDirectory: true)
        let claudeEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "api": "anthropic-messages",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 80,
                    "output": 20,
                    "cacheRead": 4,
                    "cacheWrite": 100,
                    "cttl": [
                        "ephemeral5m": 60,
                        "ephemeral1h": 40,
                    ],
                    "totalTokens": 204,
                ],
            ],
        ]
        let ompSession = ompSessionsRoot.appendingPathComponent(
            "2026-09-30T10-00-00-000Z_cttl.jsonl",
            isDirectory: false)
        try FileManager.default.createDirectory(
            at: ompSession.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try env.jsonl([claudeEntry]).write(to: ompSession, atomically: true, encoding: .utf8)

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                ompSessionsRoot: ompSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        let expected = try #require(CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 80,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 100,
            cacheCreationInputTokens1h: 40,
            outputTokens: 20,
            pricingDate: day,
            modelsDevCacheRoot: env.cacheRoot))
        #expect(report.data.count == 1)
        let actual = try #require(report.data.first?.costUSD)
        #expect(abs(actual - expected) < 0.000001)
    }

    @Test
    func `pi scanner drops rows whose one-hour subset exceeds total cache writes`() throws {
        for extras: [String: Any] in [
            ["cacheWrite1h": 200],
            ["cttl": ["ephemeral1h": 200]],
        ] {
            let env = try CostUsageTestEnvironment()
            defer { env.cleanup() }
            let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)

            var usage: [String: Any] = [
                "input": 80,
                "output": 20,
                "cacheRead": 4,
                "cacheWrite": 50,
                "totalTokens": 154,
            ]
            for (key, value) in extras {
                usage[key] = value
            }
            let claudeEntry: [String: Any] = [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "api": "anthropic-messages",
                    "model": "claude-sonnet-4-6",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": usage,
                ],
            ]

            _ = try env.writePiSessionFile(
                relativePath: "2026-09-30T10-00-00-000Z_oversized.jsonl",
                contents: env.jsonl([claudeEntry]))

            let report = PiSessionCostScanner.loadDailyReport(
                provider: .claude,
                since: day,
                until: day,
                now: day,
                options: PiSessionCostScanner.Options(
                    piSessionsRoot: env.piSessionsRoot,
                    cacheRoot: env.cacheRoot,
                    refreshMinIntervalSeconds: 0))

            #expect(report.data.isEmpty)
        }
    }

    @Test
    func `pi scanner drops rows with malformed one-hour cache counters`() throws {
        let invalidUsages: [[String: Any]] = [
            ["cacheWrite1h": NSNull()],
            ["cacheWrite1h": true],
            ["cacheWrite1h": "junk"],
            ["cacheWrite1h": -5],
            ["cacheWrite1h": 1e19],
            ["cttl": ["ephemeral1h": "junk"]],
            // A present flat spelling wins over a valid nested one, even when malformed.
            ["cacheWrite1h": "junk", "cttl": ["ephemeral1h": 40]],
        ]
        for extras in invalidUsages {
            let env = try CostUsageTestEnvironment()
            defer { env.cleanup() }
            let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)

            var usage: [String: Any] = [
                "input": 80,
                "output": 20,
                "cacheRead": 4,
                "cacheWrite": 100,
                "totalTokens": 204,
            ]
            for (key, value) in extras {
                usage[key] = value
            }
            let claudeEntry: [String: Any] = [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "api": "anthropic-messages",
                    "model": "claude-sonnet-4-6",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": usage,
                ],
            ]

            _ = try env.writePiSessionFile(
                relativePath: "2026-09-30T10-00-00-000Z_invalid.jsonl",
                contents: env.jsonl([claudeEntry]))

            let report = PiSessionCostScanner.loadDailyReport(
                provider: .claude,
                since: day,
                until: day,
                now: day,
                options: PiSessionCostScanner.Options(
                    piSessionsRoot: env.piSessionsRoot,
                    cacheRoot: env.cacheRoot,
                    refreshMinIntervalSeconds: 0))

            #expect(report.data.isEmpty)
        }
    }

    @Test
    func `pi scanner reparses a predecessor formula cache instead of serving stale prices`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)

        let claudeEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "api": "anthropic-messages",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 80,
                    "output": 20,
                    "cacheRead": 4,
                    "cacheWrite": 100,
                    "cacheWrite1h": 40,
                    "totalTokens": 204,
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-09-30T10-00-00-000Z_reprice.jsonl",
            contents: env.jsonl([claudeEntry]))

        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        let first = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        let priced = try #require(first.data.first?.costUSD)

        // Rebuild the key as a release before the cttl-aware formula would have written it:
        // current parser hash and catalog fingerprint, predecessor formula version. Poisoning
        // the stored prices makes any stale reuse visible instead of silently passing.
        var predecessor = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        predecessor.pricingKey = CostUsagePricingKey.codex(
            modelsDevArtifact: ModelsDevCache.load(now: day, cacheRoot: env.cacheRoot).artifact,
            formulaVersion: PiSessionCostScanner.costFormulaVersion - 1,
            parserHash: CodexParserHash.value,
            modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs + ["amazon-bedrock"])),
            customPricingFingerprint: CostUsageCustomPricing.load().fingerprint)
        predecessor.files = predecessor.files.mapValues { file in
            var file = file
            file.contributions = file.contributions.mapValues { days in
                days.mapValues { models in
                    models.mapValues { usage in
                        var usage = usage
                        usage.costNanos = 1
                        return usage
                    }
                }
            }
            return file
        }
        PiSessionCostCacheIO.save(cache: predecessor, cacheRoot: env.cacheRoot)

        #expect(PiSessionCostScanner.loadCachedDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot) == nil)

        let repriced = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let actual = try #require(repriced.data.first?.costUSD)
        #expect(abs(actual - priced) < 0.000001)
    }

    @Test
    func `pi scanner reads each one-hour cache write spelling`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let cases: [(extras: [String: Any], expected1h: Int)] = [
            (["cache_write_1h": 40], 40),
            (["cttl": ["ephemeral_1h": 40]], 40),
            (["cacheWrite1h": 10, "cttl": ["ephemeral1h": 40]], 10),
            (["cacheWrite1h": "40"], 40),
            (["cacheWrite1h": 40.7], 41),
            (["cttl": ["ephemeral1h": 40, "ephemeral5m": 60]], 40),
            // A non-object cttl carries no one-hour spelling, so the row reads as all-5m.
            (["cttl": "not-an-object"], 0),
            // The 5-minute bucket alone is not a one-hour subset.
            (["cttl": ["ephemeral5m": 60]], 0),
        ]
        let since = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        let until = try env.makeLocalNoon(year: 2026, month: 9, day: 20 + cases.count - 1)

        for (index, testCase) in cases.enumerated() {
            let day = try env.makeLocalNoon(year: 2026, month: 9, day: 20 + index)
            var usage: [String: Any] = [
                "input": 80,
                "output": 20,
                "cacheRead": 4,
                "cacheWrite": 100,
                "totalTokens": 204,
            ]
            for (key, value) in testCase.extras {
                usage[key] = value
            }
            let entry: [String: Any] = [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "api": "anthropic-messages",
                    "model": "claude-sonnet-4-6",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": usage,
                ],
            ]
            _ = try env.writePiSessionFile(
                relativePath: String(
                    format: "2026-09-%02dT10-00-00-000Z_variant%02d.jsonl", 20 + index, index),
                contents: env.jsonl([entry]))
        }

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: since,
            until: until,
            now: until,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(report.data.count == cases.count)
        for (index, testCase) in cases.enumerated() {
            let day = try env.makeLocalNoon(year: 2026, month: 9, day: 20 + index)
            let expected = try #require(CostUsagePricing.claudeCostUSD(
                model: "claude-sonnet-4-6",
                inputTokens: 80,
                cacheReadInputTokens: 4,
                cacheCreationInputTokens: 100,
                cacheCreationInputTokens1h: testCase.expected1h,
                outputTokens: 20,
                pricingDate: day,
                modelsDevCacheRoot: env.cacheRoot))
            let dayKey = String(format: "2026-09-%02d", 20 + index)
            let actual = try #require(report.data.first { $0.date == dayKey }?.costUSD)
            #expect(abs(actual - expected) < 0.000001)
        }
    }

    @Test
    func `pi scanner ignores one-hour cache write fields on codex rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 30)

        let codexEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 80,
                    "output": 20,
                    "cacheRead": 4,
                    "cacheWrite": 100,
                    "cacheWrite1h": 40,
                    "totalTokens": 204,
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-09-30T10-00-00-000Z_codex.jsonl",
            contents: env.jsonl([codexEntry]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        // Codex has no 1-hour tier; the subset must not leak into billed tokens.
        let expected = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 184,
            cachedInputTokens: 4,
            outputTokens: 20,
            cacheWriteInputTokens: 100,
            pricingDate: day,
            modelsDevCacheRoot: env.cacheRoot))
        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 204)
        let actual = try #require(report.data.first?.costUSD)
        #expect(abs(actual - expected) < 0.000001)
    }
}
