import Foundation

/// Swift registration data for bundled API-key plugins. Fetching and parsing stay in the plugin.
public struct PluginProviderSpec: Sendable {
    public struct APIKeyField: Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public var placeholder: String? = "Paste API key…"
        public var action: (id: String, title: String, url: String)?
    }

    public struct TextField: Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let placeholder: String?
    }

    public struct WorkspaceField: Sendable {
        public let environmentKey: String
        public let field: TextField
    }

    public let id: UsageProvider
    public let displayName: String
    public let sessionLabel: String
    public let weeklyLabel: String
    public var opusLabel: String?
    public var creditsHint = ""
    public var sharePlanLabels: [String: String] = [:]
    public var toggleTitle: String?
    public var debugLogUnavailableMessage: String?
    public var balanceOnly = false
    public var usesDetailBackedWindow = false
    public let dashboardURL: String?
    public var subscriptionDashboardURL: String?
    public var statusLinkURL: String?
    public let color: ProviderColor
    public let confetti: [UInt32]
    public var widgetColor: ProviderColor?
    public var progressColorStyle: ProviderBranding.ProgressColorStyle = .brand
    public let noDataMessage: String
    public let environmentKey: String
    public var environmentAliases: [String] = []
    public var apiKeyDebugLabel: String?
    public var missingCredentialMessage: ProviderCredentialAdapter.MissingCredentialMessage?
    public var additionalProjections: [ProviderCredentialEnvironmentProjection] = []
    public var tokenAccountSupport: TokenAccountSupport?
    public var config = ProviderConfigCapabilities()
    public var menuBarMetrics: ProviderMenuBarMetricCapabilities?
    public var presentation = ProviderUsagePresentation()
    public var aliases: [String] = []
    public var timeout = ProviderPluginRuntime.defaultTimeout
    public var scriptSettings: @Sendable (ProviderFetchContext) -> [String: String] = { _ in [:] }
    public var validateContext: ScriptFetchStrategy.ContextValidator = { _ in }
    public var apiKeyField: APIKeyField?
    public var workspaceField: WorkspaceField?
    public var showsAPIDetail = false
    public enum Availability: Sendable {
        case always
        case environmentKey
        case configuredKey
        case configuredKeyOrAccount
    }

    public var availability: Availability = .always
    public var observesTokenAccounts = false

    public func apiKey(environment: [String: String]) -> String? {
        SettingsValue.first(in: environment, keys: [self.environmentKey] + self.environmentAliases)
    }

    public func makeDescriptor(
        credentials: ProviderCredentialAdapter? = nil,
        fetchPlan: ProviderFetchPlan? = nil) -> ProviderDescriptor
    {
        ProviderDescriptor(
            id: self.id,
            menuBarMetrics: self.menuBarMetrics,
            credentials: credentials ?? .apiKey(
                environmentKey: self.environmentKey,
                apiKeyDebugLabel: self.apiKeyDebugLabel,
                additionalProjections: self.additionalProjections +
                    (self.workspaceField.map { [.workspaceID($0.environmentKey)] } ?? []),
                resolve: self.apiKey,
                tokenAccountSupport: self.tokenAccountSupport,
                missingCredentialMessage: self.missingCredentialMessage),
            config: self.config,
            metadata: ProviderMetadata(
                id: self.id,
                displayName: self.displayName,
                sessionLabel: self.sessionLabel,
                weeklyLabel: self.weeklyLabel,
                opusLabel: self.opusLabel,
                supportsOpus: self.opusLabel != nil,
                supportsCredits: false,
                creditsHint: self.creditsHint,
                toggleTitle: self.toggleTitle ?? "Show \(self.displayName) usage",
                cliName: self.id.rawValue,
                defaultEnabled: false,
                widgetSelectable: false,
                sharePlanLabels: self.sharePlanLabels,
                debugLogUnavailableMessage: self.debugLogUnavailableMessage,
                balanceOnly: self.balanceOnly,
                usesDetailBackedWindow: self.usesDetailBackedWindow,
                dashboardURL: self.dashboardURL,
                subscriptionDashboardURL: self.subscriptionDashboardURL,
                statusPageURL: nil,
                statusLinkURL: self.statusLinkURL),
            branding: ProviderBranding(
                iconStyle: .init(provider: self.id),
                iconResourceName: "ProviderIcon-\(self.id.rawValue)",
                color: self.color,
                confettiPalette: self.confetti.map { ProviderColor(hex: $0) },
                widgetColor: self.widgetColor,
                progressColorStyle: self.progressColorStyle),
            tokenCost: ProviderTokenCostConfig(supportsTokenCost: false, noDataMessage: { self.noDataMessage }),
            presentation: self.presentation,
            fetchPlan: fetchPlan ?? ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [self.makeStrategy()] })),
            cli: ProviderCLIConfig(name: self.id.rawValue, aliases: self.aliases, versionDetector: nil))
    }

    func scriptValues(_ context: ProviderFetchContext) -> ScriptFetchStrategy.Values? {
        guard let key = self.apiKey(environment: context.env) else { return nil }
        var settings = self.scriptSettings(context)
        if let field = self.workspaceField,
           let value = SettingsValue.cleaned(context.env[field.environmentKey])
        {
            settings[field.environmentKey] = value
        }
        return .init(settings: settings, secrets: [self.environmentKey: key])
    }

    func makeStrategy(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "\(self.id.rawValue).js",
            provider: self.id,
            bundledPlugin: self.id.rawValue,
            secretKey: self.environmentKey,
            sourceLabel: "api",
            transport: transport,
            timeout: self.timeout,
            validateContext: self.validateContext,
            resolveValues: self.scriptValues,
            isEnabled: { _ in true })
    }
}
