import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexRequestLedgerTests {
    private static let timestampA = "2026-08-29T15:59:00Z"
    private static let timestampB = "2026-08-29T16:01:00Z"
    private static let timestampC = "2026-08-29T16:01:05Z"

    @Test(arguments: [false, true], [false, true])
    func `request ledger recovers reset counters without counting both formats`(
        legacyFirst: Bool, spacedJSON: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var lines = Self.header()
        let requests: [(String, [Int], [Int], [Int])] = [
            (Self.timestampA, [1000, 200, 100, 40], [1000, 200, 100, 40], [1000, 200, 100, 40]),
            (Self.timestampB, [60, 20, 6, 3], [60, 20, 6, 3], [1060, 220, 106, 43]),
            (Self.timestampC, [60, 20, 6, 3], [120, 40, 12, 6], [1120, 240, 112, 46]),
        ]
        for (index, request) in requests.enumerated() {
            let (timestamp, usage, legacyTotal, threadTotal) = request
            let legacy = Self.legacy(timestamp: timestamp, usage: usage, total: legacyTotal)
            let ledger = Self.record(
                id: "response-\(index)",
                timestamp: timestamp,
                usage: usage,
                total: threadTotal,
                turnTotal: legacyTotal)
            lines += legacyFirst ? [legacy, ledger] : [ledger, legacy]
        }
        let result = try Self.parse(lines, env: env, spacedJSON: spacedJSON)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 1232)
        #expect(result.rows.filter { $0.day == "2026-08-30" }.reduce(0) { $0 + $1.input + $1.output } == 132)
        #expect(result.rows.reduce(0) { $0 + ($1.reasoning ?? 0) } == 46)
    }

    @Test
    func `ledger and legacy timestamps may differ`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.record(
                id: "one",
                timestamp: "2026-08-29T15:59:01Z",
                usage: [100, 20, 10, 4],
                total: [100, 20, 10, 4]),
        ], env: env)
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.responseID == "one")
        #expect(result.rows.first?.input == 100)
    }

    @Test(arguments: [false, true])
    func `request accounting survives append and SQLite reopen`(legacyFirst: Bool) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let first = Self.record(id: "one", usage: [1000, 200, 100, 40], total: [1000, 200, 100, 40])
        let mirror = Self.legacy(
            timestamp: Self.timestampA,
            usage: [1000, 200, 100, 40],
            total: [1000, 200, 100, 40])
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "synthetic-ledger.jsonl",
            contents: env.jsonl(Self.header() + [legacyFirst ? mirror : first]))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        func fetch(_ now: Date) async throws -> CostUsageTokenSnapshot {
            try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                environment: [:],
                now: now,
                forceRefresh: true,
                historyDays: 30,
                allowPricingRefresh: false,
                includePiSessions: false,
                scannerOptions: options)
        }
        let initial = try await fetch(start)
        #expect(initial.sessionTokens == 1100)
        _ = await CostUsageStore(cacheRoot: env.cacheRoot).readSnapshot()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            legacyFirst ? first : mirror,
            Self.record(
                id: "two",
                timestamp: Self.timestampB,
                usage: [60, 20, 6, 3],
                total: [1060, 220, 106, 43],
                turnTotal: [60, 20, 6, 3]),
            Self.legacy(timestamp: Self.timestampB, usage: [60, 20, 6, 3], total: [60, 20, 6, 3]),
            Self.record(
                id: "three",
                timestamp: Self.timestampC,
                usage: [60, 20, 6, 3],
                total: [1120, 240, 112, 46],
                turnTotal: [120, 40, 12, 6]),
            Self.legacy(timestamp: Self.timestampC, usage: [60, 20, 6, 3], total: [120, 40, 12, 6]),
        ]).utf8))
        try handle.close()
        let resumed = try await fetch(end)
        #expect(resumed.sessionTokens == 132)
        let saved = await CostUsageStore(cacheRoot: env.cacheRoot).readSnapshot()
        #expect(saved.files.allSatisfy { $0.scanState.isComplete == true })
        let stable = try await fetch(end.addingTimeInterval(120))
        #expect(stable.daily == resumed.daily)
        let reopened = await CostUsageStore(cacheRoot: env.cacheRoot).readSnapshot()
        #expect(reopened.usageRows == saved.usageRows)
    }

    @Test
    func `request identity suppresses replay even when replayed counters change`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [200, 40, 20, 8]),
            Self.record(id: "two", usage: [100, 20, 10, 4], total: [300, 60, 30, 12]),
        ], env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    @Test(arguments: [false, true])
    func `replayed identities also suppress legacy mirrors with changed counters`(legacyFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let replay = Self.record(id: "one", usage: [100, 20, 10, 4], total: [200, 40, 20, 8])
        let mirror = Self.legacy(timestamp: Self.timestampB, usage: [100, 20, 10, 4], total: [200, 40, 20, 8])
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
        ] + (legacyFirst ? [mirror, replay] : [replay, mirror]), env: env)
        #expect(result.rows.count == 1)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 110)
    }

    @Test
    func `copied parent request records are not billed to a child`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "copied", owner: "parent", usage: [1000, 200, 100, 40], total: [1000, 200, 100, 40]),
            Self.record(id: "owned", usage: [60, 20, 6, 3], total: [1060, 220, 106, 43]),
        ], env: env)
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.input == 60)
        #expect(result.rows.first?.output == 6)
    }

    @Test
    func `legacy prefix remains when request records start later`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.legacy(timestamp: Self.timestampA, usage: [1000, 200, 100, 40], total: [1000, 200, 100, 40]),
            Self.record(id: "new", timestamp: Self.timestampB, usage: [60, 20, 6, 3], total: [1060, 220, 106, 43]),
            Self.legacy(timestamp: Self.timestampB, usage: [60, 20, 6, 3], total: [60, 20, 6, 3]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 1166)
        #expect(result.rows.map(\.day) == ["2026-08-29", "2026-08-30"])
    }

    @Test
    func `legacy-only requests between ledger requests remain counted`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampB, usage: [50, 10, 5, 2], total: [150, 30, 15, 6]),
            Self.record(
                id: "three",
                timestamp: Self.timestampC,
                usage: [60, 20, 6, 3],
                total: [210, 50, 21, 9]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 231)
    }

    @Test
    func `archived copies deduplicate by response identity rather than page index`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
        ], env: env)
        var state = CostUsageScanner.CodexScanState()
        CostUsageScanner.rememberCodexRows(
            result.rows,
            sessionId: "synthetic-thread",
            fileIdentity: "page-one",
            state: &state)
        let duplicate = CostUsageScanner.CodexUsageRow(
            day: "2026-08-30",
            model: "gpt-5",
            turnID: "synthetic-turn",
            eventIndex: 42,
            input: 100,
            cached: 20,
            output: 10,
            responseID: "one")
        let unique = CostUsageScanner.uniqueCodexRows(
            rows: [duplicate],
            sessionId: "synthetic-thread",
            fileIdentity: "archive-copy",
            state: &state)
        #expect(unique.isEmpty)
        let anotherThread = CostUsageScanner.uniqueCodexRows(
            rows: [duplicate],
            sessionId: "another-thread",
            fileIdentity: "other",
            state: &state)
        #expect(anotherThread.count == 1)
    }

    @Test(arguments: [false, true])
    func `separate legacy and ledger pages count a mirrored request once`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let ledger = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
        ], env: env)
        let legacy = try Self.parse(Self.header() + [
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
        ], env: env)
        var state = CostUsageScanner.CodexScanState()
        let first = ledgerFirst ? ledger.rows : legacy.rows
        let second = ledgerFirst ? legacy.rows : ledger.rows
        let accepted = CostUsageScanner.uniqueCodexRows(
            rows: first,
            sessionId: "synthetic-thread",
            fileIdentity: "first",
            state: &state)
        let mirrored = CostUsageScanner.uniqueCodexRows(
            rows: second,
            sessionId: "synthetic-thread",
            fileIdentity: "second",
            state: &state)
        #expect(accepted.count == 1)
        #expect(mirrored.isEmpty)
    }

    @Test
    func `totals-only legacy requests retain their baseline after a ledger mirror`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            ["type": "event_msg", "timestamp": Self.timestampB, "payload": [
                "type": "token_count", "info": ["total_token_usage": Self.tokens([150, 30, 15, 6])],
            ]],
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 165)
    }

    @Test
    func `invalid ledger does not disable legacy accounting`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var invalid = Self.record(id: "invalid", usage: [100, 20, 10, 4], total: [100, 20, 10, 4])
        var payload = try #require(invalid["payload"] as? [String: Any])
        payload["usage"] = ["input_tokens": true, "cached_input_tokens": 20, "output_tokens": 10]
        invalid["payload"] = payload
        let result = try Self.parse(Self.header() + [
            invalid,
            Self.legacy(
                timestamp: Self.timestampA,
                usage: [100, 20, 10, 4],
                total: [100, 20, 10, 4]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 110)
    }

    private static func parse(_ lines: [[String: Any]], env: CostUsageTestEnvironment, spacedJSON: Bool = false) throws
        -> CostUsageScanner.CodexParseResult
    {
        let file = env.root.appendingPathComponent("synthetic.jsonl")
        let content = try env.jsonl(lines)
        try (spacedJSON ? content.replacingOccurrences(of: "\":", with: "\": ") : content)
            .write(to: file, atomically: false, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        return CostUsageScanner.parseCodexFile(
            fileURL: file, range: .init(since: start, until: end, calendar: calendar))
    }

    private static func header() -> [[String: Any]] {
        [
            ["type": "session_meta", "timestamp": self.timestampA, "payload": ["id": "synthetic-thread"]],
            [
                "type": "turn_context",
                "timestamp": self.timestampA,
                "payload": ["turn_id": "synthetic-turn", "model": "gpt-5"],
            ],
        ]
    }

    private static func tokens(_ values: [Int]) -> [String: Int] {
        [
            "input_tokens": values[0],
            "cached_input_tokens": values[1],
            "output_tokens": values[2],
            "reasoning_output_tokens": values[3],
        ]
    }

    private static func record(
        id: String,
        owner: String = "synthetic-thread",
        timestamp: String = timestampA,
        usage: [Int],
        total: [Int],
        turnTotal: [Int]? = nil) -> [String: Any]
    {
        ["type": "token_usage_record", "timestamp": timestamp, "payload": [
            "thread_id": owner, "session_id": owner, "turn_id": "synthetic-turn", "response_id": id,
            "usage": self.tokens(usage), "thread_token_usage": self.tokens(total),
            "turn_token_usage": self.tokens(turnTotal ?? total),
        ]]
    }

    private static func legacy(timestamp: String, usage: [Int], total: [Int]) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp, "payload": [
            "type": "token_count", "turn_id": "synthetic-turn", "info": [
                "last_token_usage": self.tokens(usage), "total_token_usage": self.tokens(total),
            ],
        ]]
    }
}
