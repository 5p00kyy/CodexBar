import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MistralMonthlyPlanPickerTests {
    @Test
    func `menu bar metric picker stores Monthly Plan for the menu bar and widgets`() {
        let settings = testSettingsStore(
            suiteName: "MistralMonthlyPlanPickerTests",
            userDefaults: InMemoryUserDefaults())
        let view = ProviderMenuBarPercentWindowSettingsView(provider: .mistral, settings: settings)
        view.layoutBinding.wrappedValue = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let picker = ProviderMenuBarPercentWindowPicker(
            provider: .mistral,
            iconStyle: .iconAndPercent,
            layout: view.layoutBinding,
            metric: view.metricBinding)
        #expect(MenuBarPercentWindowPreference.monthlyPlan.label(for: .mistral) == "Monthly Plan")
        #expect(picker.selectionBinding.wrappedValue == .automatic)

        picker.selectionBinding.wrappedValue = .monthlyPlan
        #expect(settings.menuBarMetricPreference(for: .mistral) == .monthlyPlan)
        #expect(settings.menuBarLayout(for: .mistral).lines == [[.icon, .percent(window: .automatic)]])
        #expect(picker.selectionBinding.wrappedValue == .monthlyPlan)

        picker.selectionBinding.wrappedValue = .session
        #expect(settings.menuBarMetricPreference(for: .mistral) == .automatic)
        #expect(settings.menuBarLayout(for: .mistral).lines == [[.icon, .percent(window: .session)]])
        #expect(picker.selectionBinding.wrappedValue == .session)

        picker.selectionBinding.wrappedValue = .monthlyPlan
        picker.selectionBinding.wrappedValue = .automatic
        #expect(settings.menuBarMetricPreference(for: .mistral) == .automatic)
        #expect(picker.selectionBinding.wrappedValue == .automatic)
    }
}
