import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct QuotaBurndownRenderProofTests {
    @Test
    func `render current window from synthetic quota samples`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_BURNDOWN_PROOF_PATH"] else { return }
        let now = Date()
        let reset = now.addingTimeInterval(2 * 3600)
        let history = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [
                .init(capturedAt: now.addingTimeInterval(-2 * 3600), usedPercent: 10, resetsAt: reset),
                .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 35, resetsAt: reset),
                .init(capturedAt: now.addingTimeInterval(-1800), usedPercent: 48, resetsAt: reset),
            ])
        let current = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: history.entries + [
                .init(capturedAt: now, usedPercent: 60, resetsAt: reset),
            ])
        let view = QuotaBurndownChartMenuView(
            provider: .codex,
            histories: [current],
            width: 400,
            referenceDate: now)
            .frame(width: 400)
            .padding(12)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
