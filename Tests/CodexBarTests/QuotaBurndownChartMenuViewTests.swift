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
                    .init(capturedAt: now, usedPercent: 70, resetsAt: now.addingTimeInterval(7200)),
                ]),
        ]

        let view = QuotaBurndownChartMenuView(
            provider: .claude,
            histories: histories,
            width: 400,
            referenceDate: now)

        #expect(view._seriesRemainingForTesting["weekly:10080"] == 80)
        #expect(view._seriesRemainingForTesting["opus:10080"] == 30)
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
