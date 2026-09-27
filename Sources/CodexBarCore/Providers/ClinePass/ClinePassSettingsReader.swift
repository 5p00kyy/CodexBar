import Foundation

public enum ClinePassSettingsReader {
    public static let alternateAPIKeyEnvironmentKey = ClinePassProviderDescriptor.spec.environmentAliases[0]

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        ClinePassProviderDescriptor.spec.apiKey(environment: environment)
    }
}
