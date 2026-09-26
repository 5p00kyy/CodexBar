import CodexBarCore
import Foundation

struct PluginAPIKeyProviderImplementation: ProviderImplementation {
    let spec: PluginProviderSpec
    var id: UsageProvider {
        self.spec.id
    }

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            self.spec.showsAPIDetail ? "api" : ProviderPresentation.standardDetailLine(context: context)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: self.id, field: .apiKey]
        if self.spec.workspaceField != nil {
            _ = settings[providerConfig: self.id, field: .workspace]
        }
        if self.spec.observesTokenAccounts {
            _ = settings.tokenAccountsData(for: self.id)
        }
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if self.spec.availability == .always { return true }
        if self.spec.apiKey(environment: context.environment) != nil ||
            ProviderDescriptorRegistry.descriptor(for: self.id).credentials?
            .resolveToken(environment: context.environment) != nil { return true }
        if self.spec.availability == .environmentKey { return false }
        if !context.settings[providerConfig: self.id, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return self.spec.availability == .configuredKeyOrAccount &&
            !context.settings.tokenAccounts(for: self.id).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        guard let field = self.spec.apiKeyField else { return [] }
        var fields = [ProviderSettingsFieldDescriptor(
            id: field.id,
            title: field.title,
            subtitle: field.subtitle,
            kind: .secure,
            placeholder: field.placeholder,
            binding: context.providerConfigBinding(.apiKey),
            actions: field.action.map { [.openURL(id: $0.id, title: $0.title, url: URL(string: $0.url))] } ?? [],
            isVisible: nil)]
        if let workspace = self.spec.workspaceField {
            fields.append(ProviderSettingsFieldDescriptor(
                id: workspace.field.id,
                title: workspace.field.title,
                subtitle: workspace.field.subtitle,
                kind: .plain,
                placeholder: workspace.field.placeholder,
                binding: context.providerConfigBinding(.workspace),
                actions: [],
                isVisible: nil))
        }
        return fields
    }
}
