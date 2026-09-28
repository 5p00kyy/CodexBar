import Foundation
import Testing
@testable import CodexBar

@MainActor
struct QuotaBurndownChartMenuViewTests {
    @Test
    func `keeps same duration quota lanes separate`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [
                    .init(capturedAt: now, usedPercent: 20, resetsAt: now.addingTimeInterval(3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .opus,
                windowMinutes: 10080,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-7200),
                        usedPercent: 70,
                        resetsAt: now.addingTimeInterval(7200)),
                ]),
        ]

        let view = QuotaBurndownChartMenuView(
            provider: .claude,
            histories: histories,
            width: 400,
            referenceDate: now)

        #expect(view._seriesRemainingForTesting["weekly:10080"] == 80)
        #expect(view._seriesRemainingForTesting["opus:10080"] == 30)
        #expect(view._seriesLastKnownMessagesForTesting["weekly:10080"] == LastKnownUsagePresentation.message(
            capturedAt: now,
            now: now))
        #expect(view._seriesLastKnownMessagesForTesting["opus:10080"] == LastKnownUsagePresentation.message(
            capturedAt: now.addingTimeInterval(-7200),
            now: now))
    }

    @Test(arguments: [60.0, 21600.0, 172_800.0])
    func `saved weekly usage reports actual capture time rather than current time`(age: TimeInterval) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let capturedAt = now.addingTimeInterval(-age)
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [.init(capturedAt: capturedAt, usedPercent: 40, resetsAt: now.addingTimeInterval(86400))])
        let view = QuotaBurndownChartMenuView(
            provider: .codex,
            histories: [history],
            width: 400,
            referenceDate: now)

        #expect(view.hasSeries)
        #expect(view._seriesRemainingForTesting["weekly:10080"] == 60)
        #expect(view._seriesLastKnownMessagesForTesting["weekly:10080"] == LastKnownUsagePresentation.message(
            capturedAt: capturedAt,
            now: now))
        #expect(view._seriesLastKnownMessagesForTesting["weekly:10080"] != LastKnownUsagePresentation.message(
            capturedAt: now,
            now: now))
    }

    @Test
    func `hides a completed reset window`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [
                .init(
                    capturedAt: now.addingTimeInterval(-3600),
                    usedPercent: 40,
                    resetsAt: now.addingTimeInterval(-1)),
            ])

        let view = QuotaBurndownChartMenuView(
            provider: .codex,
            histories: [history],
            width: 400,
            referenceDate: now)

        #expect(!view.hasSeries)
    }
}
