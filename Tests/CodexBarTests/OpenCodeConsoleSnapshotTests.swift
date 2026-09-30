import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeConsoleSnapshotTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `unknown Console resets remain unknown`() {
        let snapshot = OpenCodeUsageSnapshot(
            rollingUsagePercent: 17,
            weeklyUsagePercent: 75,
            rollingResetInSec: nil,
            weeklyResetInSec: nil,
            updatedAt: Self.now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 17)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.secondary?.usedPercent == 75)
        #expect(usage.secondary?.resetsAt == nil)
    }

    @Test
    func `missing Console weekly quota does not appear as unused quota`() {
        let snapshot = OpenCodeUsageSnapshot(
            hasWeeklyUsage: false,
            rollingUsagePercent: 17,
            weeklyUsagePercent: 0,
            rollingResetInSec: 600,
            weeklyResetInSec: nil,
            updatedAt: Self.now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 17)
        #expect(usage.primary?.resetsAt == Self.now.addingTimeInterval(600))
        #expect(usage.secondary == nil)
    }

    @Test
    func `zero usage and immediate reset remain valid supplied quota values`() {
        let snapshot = OpenCodeUsageSnapshot(
            rollingUsagePercent: 0,
            weeklyUsagePercent: 0,
            rollingResetInSec: 0,
            weeklyResetInSec: 0,
            updatedAt: Self.now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetsAt == Self.now)
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.secondary?.resetsAt == Self.now)
    }

    @Test
    func `Console spend keeps its rolling thirty day period`() {
        let snapshot = OpenCodeUsageSnapshot.payAsYouGo(
            .init(usageUSD: 3.25, limitUSD: nil, balanceUSD: 12.5, period: .last30Days),
            updatedAt: Self.now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost?.used == 3.25)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.balance == 12.5)
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(usage.providerCost?.currencyCode == "USD")
    }

    @Test
    func `rolling spend cannot consume a monthly quota`() {
        let payAsYouGo = OpenCodeUsageSnapshot.PayAsYouGoUsage(
            usageUSD: 15,
            limitUSD: 20,
            balanceUSD: nil,
            period: .last30Days)
        let usage = OpenCodeUsageSnapshot.payAsYouGo(payAsYouGo, updatedAt: Self.now).toUsageSnapshot()

        #expect(payAsYouGo.usedPercent == nil)
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.limit == 0)
    }
}
