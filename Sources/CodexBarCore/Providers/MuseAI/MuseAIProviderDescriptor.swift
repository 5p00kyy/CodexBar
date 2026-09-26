import Foundation

public enum MuseAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .museai,
        displayName: "Muse",
        sessionLabel: "Weekly",
        weeklyLabel: "Plan",
        dashboardURL: "https://muse.ai/?settings_tab=general",
        color: .init(hex: 0x0668E1),
        confetti: [0x0668E1, 0x8B5CF6, 0xFFFFFF],
        noDataMessage: "muse.ai reports a weekly usage percentage, not a cost history.",
        menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
        // Paid plans report "2.8B tokens left" in resetDescription; show it beside the reset countdown.
        presentation: ProviderUsagePresentation(
            menuCard: ProviderMenuCardPresentation(showsPrimaryBalanceDescription: true)),
        webSource: .init(
            settingsSection: .init(MuseAIProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            resolveValues: { $0.settings?.museai?.cookieSource == .off ? nil : .init() },
            field: .init(
                id: "museai-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a signed-in muse.ai request.",
                placeholder: "Cookie: …"),
            picker: .init(
                id: "museai-cookie-source",
                allowsOff: true,
                auto: .localized("Automatically imports browser cookies."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "muse.ai"),
                off: .localized("%@ cookies are disabled.", argument: "Muse")),
            detailLine: "Browser cookies",
            showsVersionInSettings: false))
}

public enum MuseAIProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.museai
    public typealias Section = CookieProviderSettings
}

extension ProviderSettingsSnapshot {
    public var museai: CookieProviderSettings? {
        self[MuseAIProviderSettingsKey.self]
    }
}
