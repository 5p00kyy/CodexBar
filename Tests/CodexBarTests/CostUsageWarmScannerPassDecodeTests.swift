import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageWarmScannerPassDecodeTests {
    /// Real scanner passes over an unchanged corpus. After the first pass builds the cache, later passes have
    /// nothing to parse, so they should reuse the retained decoded baseline instead of decoding every row.
    @Test(arguments: [0, 300])
    func `warm scanner passes over an unchanged corpus reuse the decoded baseline`(
        refreshMinIntervalSeconds: Int) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let iso = env.isoString(for: day)
        for index in 0..<16 {
            var lines = [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"id":"warm-\#(index)"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.4"}}"#,
            ]
            for turn in 1...8 {
                lines.append(#"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","#
                    + #""info":{"total_token_usage":{"input_tokens":\#(turn * 10),"cached_input_tokens":\#(turn),"#
                    + #""output_tokens":\#(turn * 3)}}}}"#)
            }
            _ = try env.writeCodexSessionFile(
                day: day, filename: "warm-\(index).jsonl", contents: lines.joined(separator: "\n") + "\n")
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"))
        options.refreshMinIntervalSeconds = TimeInterval(refreshMinIntervalSeconds)
        let databaseURL = CostUsageStore(cacheRoot: env.cacheRoot).databaseURL
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)

        var warmDecodes: [Int] = []
        for pass in 1...3 {
            let recorder = CostUsageStoreReadWorkRecorder(databaseURL: databaseURL)
            var hooks = CostUsageStoreTestHooks.current
            hooks.readWorkRecorder = recorder
            // Space passes like background refreshes so interval-gated work is due each time.
            let now = day.addingTimeInterval(Double(pass * max(refreshMinIntervalSeconds, 1) + pass))
            CostUsageStoreTestHooks.$current.withValue(hooks) {
                _ = CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: day,
                    until: day,
                    now: now,
                    options: options)
            }
            warmDecodes.append(recorder.snapshot().usageRowDecodeAttempts)
        }
        print("[warm-scanner-pass] refreshMin=\(refreshMinIntervalSeconds)s warm_pass_decodes=\(warmDecodes)")
        #expect(warmDecodes.dropFirst().allSatisfy { $0 == 0 })
    }
}

extension CostUsageWarmScannerPassDecodeTests {
    @Test(arguments: [false, true], ["none", "rows", "metadata"])
    func `metadata saves retain only a baseline certified before commit`(
        advanceCursor: Bool, externalWrite: String) throws
    {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var incoming = loaded.cache
        incoming.lastScanUnixMs += 1000
        if advanceCursor {
            incoming.codexPriorityTurnsCursor = .init(
                databasePath: fixture.env.root.appendingPathComponent("synthetic-trace.sqlite").path,
                coverageSinceEpoch: 0,
                lastRowID: 7,
                fileIdentity: 1,
                anchorRowID: 7,
                anchorDigest: "synthetic",
                turns: [:],
                requestSourcesByTurnID: [:],
                priorityCompletedModelsByTurnID: [:],
                completedModelsByTurnID: [:],
                completedTurnIDInsertionOrder: [],
                completedTurnIDInsertionOrderStartIndex: 0)
        }
        var hooks = CostUsageStoreTestHooks.current
        hooks.identicalContentPostCommitCheckpoint = (fixture.store.databaseURL, {
            do {
                if externalWrite == "rows" {
                    try writer.execute("DELETE FROM usage_rows WHERE rowid = (SELECT MIN(rowid) FROM usage_rows)")
                } else if externalWrite == "metadata" {
                    try writer.execute("""
                    UPDATE scan_metadata SET payload = json_set(CAST(payload AS TEXT), '$.lastScanUnixMs', 12345)
                    """)
                }
            } catch { Issue.record(error) }
        })
        #expect(!CostUsageStoreTestHooks.$current.withValue(hooks) {
            fixture.save(incoming, load: loaded)
        }.catchUpRequired)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var reads = CostUsageStoreTestHooks.current
        reads.readWorkRecorder = recorder
        let fresh = CostUsageStoreTestHooks.$current.withValue(reads) {
            fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        }
        defer { fresh.release() }
        let work = recorder.snapshot()
        #expect(work
            .usageRowDecodeAttempts ==
            (externalWrite == "none" ? 0 : fixture.rowCount - (externalWrite == "rows" ? 1 : 0)))
        #expect(fresh.cache.lastScanUnixMs == (externalWrite == "metadata" ? 12345 : incoming.lastScanUnixMs))
        #expect(fresh.cache.codexPriorityTurnsCursor == incoming.codexPriorityTurnsCursor)
        #expect(fresh.cache.files.values.reduce(0) { $0 + ($1.codexRows?.count ?? 0) }
            == fixture.rowCount - (externalWrite == "rows" ? 1 : 0))
    }
}
