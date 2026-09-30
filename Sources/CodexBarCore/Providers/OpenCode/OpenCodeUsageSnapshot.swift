import Foundation

public struct OpenCodeUsageSnapshot: Sendable {
    /// Spend of a pay-as-you-go Zen workspace, which bills per request instead of
    /// exposing the rolling/weekly quota windows subscription workspaces report.
    public struct PayAsYouGoUsage: Equatable, Sendable {
        public enum Period: Equatable, Sendable {
            case monthly
            case last30Days
        }

        public let usageUSD: Double
        public let limitUSD: Double?
        public let balanceUSD: Double?
        public let period: Period

        public init(usageUSD: Double, limitUSD: Double?, balanceUSD: Double?, period: Period = .monthly) {
            self.usageUSD = usageUSD
            self.limitUSD = limitUSD
            self.balanceUSD = balanceUSD
            self.period = period
        }

        /// Percent of the configured monthly limit consumed. Rolling spend cannot be compared
        /// with a calendar-month limit, so it has no percentage even if a limit is supplied.
        public var usedPercent: Double? {
            guard self.period == .monthly, let limit = self.limitUSD, limit > 0 else { return nil }
            return min(100, max(0, (self.usageUSD / limit) * 100))
        }
    }

    public let hasWeeklyUsage: Bool
    public let rollingUsagePercent: Double
    public let weeklyUsagePercent: Double
    public let rollingResetInSec: Int?
    public let weeklyResetInSec: Int?
    public let renewsAt: Date?
    public let payAsYouGo: PayAsYouGoUsage?
    public let updatedAt: Date

    public init(
        hasWeeklyUsage: Bool = true,
        rollingUsagePercent: Double,
        weeklyUsagePercent: Double,
        rollingResetInSec: Int?,
        weeklyResetInSec: Int?,
        renewsAt: Date? = nil,
        payAsYouGo: PayAsYouGoUsage? = nil,
        updatedAt: Date)
    {
        self.hasWeeklyUsage = hasWeeklyUsage
        self.rollingUsagePercent = rollingUsagePercent
        self.weeklyUsagePercent = weeklyUsagePercent
        self.rollingResetInSec = rollingResetInSec
        self.weeklyResetInSec = weeklyResetInSec
        self.renewsAt = renewsAt
        self.payAsYouGo = payAsYouGo
        self.updatedAt = updatedAt
    }

    public static func payAsYouGo(
        _ usage: PayAsYouGoUsage,
        updatedAt: Date) -> OpenCodeUsageSnapshot
    {
        OpenCodeUsageSnapshot(
            rollingUsagePercent: 0,
            weeklyUsagePercent: 0,
            rollingResetInSec: 0,
            weeklyResetInSec: 0,
            payAsYouGo: usage,
            updatedAt: updatedAt)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        if let payAsYouGo = self.payAsYouGo {
            return self.payAsYouGoUsageSnapshot(payAsYouGo)
        }

        let rollingReset = self.rollingResetInSec.map { self.updatedAt.addingTimeInterval(TimeInterval($0)) }
        let primary = RateWindow(
            usedPercent: self.rollingUsagePercent,
            windowMinutes: 5 * 60,
            resetsAt: rollingReset,
            resetDescription: nil)
        let secondary: RateWindow?
        if self.hasWeeklyUsage {
            let weeklyReset = self.weeklyResetInSec.map { self.updatedAt.addingTimeInterval(TimeInterval($0)) }
            secondary = RateWindow(
                usedPercent: self.weeklyUsagePercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil)
        } else {
            secondary = nil
        }

        var extraWindows: [NamedRateWindow]?
        if let renewsAt = self.renewsAt {
            let renewalWindow = RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: renewsAt,
                resetDescription: nil)
            extraWindows = [NamedRateWindow(id: "renewal", title: "Renews", window: renewalWindow)]
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: extraWindows,
            updatedAt: self.updatedAt,
            identity: nil)
    }

    /// Renders monthly spend as the primary window when a spend limit exists, and always surfaces
    /// spend plus remaining prepaid balance as cost. The billing payload carries no cycle boundary,
    /// so `resetsAt` stays `nil` rather than guessing one.
    ///
    /// A workspace with no configured limit reports `limit: 0`, the same convention the OpenAI and
    /// ClawRouter providers use for limitless spend; the menu card renders that case as a plain
    /// spend line instead of a percentage.
    private func payAsYouGoUsageSnapshot(_ usage: PayAsYouGoUsage) -> UsageSnapshot {
        let primary = usage.usedPercent.map { percent in
            RateWindow(
                usedPercent: percent,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil)
        }
        let cost = ProviderCostSnapshot(
            used: usage.usageUSD,
            limit: usage.period == .monthly ? usage.limitUSD ?? 0 : 0,
            currencyCode: "USD",
            period: usage.period == .monthly ? "Monthly" : "Last 30 days",
            balance: usage.balanceUSD,
            updatedAt: self.updatedAt)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: cost,
            updatedAt: self.updatedAt,
            identity: nil)
    }
}
