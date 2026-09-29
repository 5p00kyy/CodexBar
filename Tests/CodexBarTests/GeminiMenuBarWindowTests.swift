import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct GeminiMenuBarWindowTests {
    @Test
    func `gemini metrics fall back to Flash Lite when Pro and Flash are unavailable`() throws {
        let snapshot = try GeminiStatusProbe.parse(text: """
        gemini-2.5-flash-lite                       12       60.0% (Resets in 6h)
        """).toUsageSnapshot()
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)

        for preference in [MenuBarMetricPreference.automatic, .primary, .secondary, .average] {
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .gemini,
                snapshot: snapshot,
                supportsAverage: true)

            #expect(window?.usedPercent == 40, "Failed preference: \(preference)")
        }
    }

    @Test
    func `gemini metrics keep Pro over Flash Lite when Flash is unavailable`() throws {
        let snapshot = try GeminiStatusProbe.parse(text: """
        gemini-2.5-pro                               3       70.0% (Resets in 24h)
        gemini-2.5-flash-lite                       12       60.0% (Resets in 6h)
        """).toUsageSnapshot()

        for preference in [MenuBarMetricPreference.automatic, .primary, .secondary, .average] {
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .gemini,
                snapshot: snapshot,
                supportsAverage: true)

            #expect(window?.usedPercent == 30, "Failed preference: \(preference)")
        }
    }
}
