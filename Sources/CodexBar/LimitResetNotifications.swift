import CodexBarCore
import Foundation

enum LimitResetNotificationLogic {
    /// A depleted session that comes back already posts "session restored" in the same refresh.
    static let sessionRestoredDedupInterval: TimeInterval = 10 * 60

    static func notificationIDPrefix(provider: UsageProvider, window: QuotaWarningWindow) -> String {
        "limit-reset-\(provider.rawValue)-\(window.rawValue)"
    }

    static func notificationCopy(
        providerName: String,
        window: QuotaWarningWindow,
        accountDisplayName: String?) -> (title: String, body: String)
    {
        let title = L("limit_reset_notification_title", providerName, window.localizedNotificationDisplayName)
        let body = if let accountDisplayName {
            L("limit_reset_notification_body_with_account", accountDisplayName)
        } else {
            L("limit_reset_notification_body")
        }
        return (title, body)
    }

    static func suppressesSessionReset(restoredPostedAt: Date?, now: Date) -> Bool {
        guard let restoredPostedAt else { return false }
        return abs(now.timeIntervalSince(restoredPostedAt)) < self.sessionRestoredDedupInterval
    }
}

@MainActor
extension UsageStore {
    func postLimitResetNotificationIfNeeded(
        provider: UsageProvider,
        window: QuotaWarningWindow,
        accountLabel: String?,
        now: Date = Date())
    {
        guard self.settings.limitResetNotificationsEnabled else { return }
        if window == .session,
           LimitResetNotificationLogic.suppressesSessionReset(
               restoredPostedAt: self.sessionRestoredNotificationPostedAt[provider.instanceID],
               now: now)
        {
            self.sessionQuotaLogger.debug(
                "session reset notice covered by session restored: provider=\(provider.rawValue)")
            return
        }
        let trimmedLabel = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountDisplayName = self.settings.hidePersonalInfo || trimmedLabel?.isEmpty != false
            ? nil
            : trimmedLabel
        self.sessionQuotaNotifier.postLimitReset(
            provider: provider,
            window: window,
            accountDisplayName: accountDisplayName)
    }
}
