#if DEBUG
import AppKit
import CodexBarCore

/// A separate, opt-in process exercises the production lazy submenu with synthetic captures.
@MainActor
enum QuotaBurndownNativeProof {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--quota-burndown-proof") else { return false }
        // SettingsStore has no injected app-group migration switch. Its existing test gate also
        // disables shared defaults, login-item registration, and automatic background work.
        setenv("SWIFT_TESTING_ENABLED", "1", 1)
        guard TestProcessSafety.isRunning, SettingsStore.isRunningTests else {
            FileHandle.standardError.write(Data("Quota proof requires isolated process safety gates.\n".utf8))
            return true
        }
        KeychainAccessGate.isDisabled = true
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private var controller: StatusItemController?
        private var store: UsageStore?
        private var settings: SettingsStore?
        private var item: NSStatusItem?
        private var directory: URL?
        private var window: NSWindow?
        private var stale = false

        func applicationDidFinishLaunching(_ notification: Notification) {
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CodexBar-quota-proof-\(UUID().uuidString)", isDirectory: true)
                self.directory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let configStore = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
                try configStore.save(CodexBarConfig(providers: UsageProvider.allCases.map {
                    // Provider-specific by design: this native proof enables only synthetic Codex quota lanes.
                    ProviderConfig(id: $0.instanceID, enabled: $0 == .codex)
                }))
                let defaults = ProofDefaults(values: [
                    "debugDisableKeychainAccess": true,
                    "agentSessionsEnabled": false,
                    "openAIWebAccessEnabled": false,
                    "launchAtLogin": false,
                ])
                let settings = SettingsStore(
                    userDefaults: defaults,
                    configStore: configStore,
                    tokenAccountStore: FileTokenAccountStore(fileURL: directory
                        .appendingPathComponent("accounts.json")),
                    antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                        fileURL: directory.appendingPathComponent("antigravity.json")),
                    performInitialProviderDetection: false)
                // Ownership selection otherwise consults real Codex auth state even without polling.
                settings._test_codexAccountSnapshotLoader = { source in
                    CodexAccountReconciliationSnapshot(
                        storedAccounts: [],
                        activeStoredAccount: nil,
                        liveSystemAccount: nil,
                        matchingStoredAccountForLiveSystemAccount: nil,
                        activeSource: source,
                        hasUnreadableAddedAccountStore: false)
                }
                let environment = ["HOME": directory.path, "CODEX_HOME": directory.path]
                let store = UsageStore(
                    fetcher: UsageFetcher(environment: environment),
                    browserDetection: BrowserDetection(cacheTTL: 0),
                    settings: settings,
                    historicalUsageHistoryStore: HistoricalUsageHistoryStore(
                        fileURL: directory.appendingPathComponent("historical.json")),
                    planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
                    startupBehavior: .testing,
                    environmentBase: environment,
                    widgetTimelineReloader: {})
                let controller = StatusItemController(
                    store: store,
                    settings: settings,
                    account: AccountInfo(email: nil, plan: nil),
                    updater: DisabledUpdaterController(),
                    preferencesSelection: PreferencesSelection(),
                    menuCardRenderingEnabled: true,
                    menuRefreshEnabled: false,
                    observeProviderConfigNotifications: false)
                controller.statusItem.isVisible = false
                self.settings = settings
                self.store = store
                self.controller = controller
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.title = "Quota proof"
                item.button?.setAccessibilityIdentifier("codexbar-synthetic-quota-proof")
                self.item = item
                self.rebuildMenu()
                self.showProofWindow()
            } catch {
                FileHandle.standardError.write(Data("Quota proof failed: \(error)\n".utf8))
                NSApplication.shared.terminate(nil)
            }
        }

        private func showProofWindow() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "CodexBar native menu proof"
            let label = NSTextField(wrappingLabelWithString:
                "Synthetic data only. Open Plan Usage, then choose Weekly in the burndown chart. "
                    + "The historical chart remains below. No accounts or providers are contacted.")
            label.frame = NSRect(x: 24, y: 105, width: 512, height: 70)
            window.contentView?.addSubview(label)
            let button = NSButton(title: "Open Plan Usage", target: self, action: #selector(self.openMenu(_:)))
            button.frame = NSRect(x: 24, y: 45, width: 180, height: 34)
            window.contentView?.addSubview(button)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.window = window
        }

        @objc private func openMenu(_ sender: NSButton) {
            self.item?.menu?.popUp(
                positioning: nil,
                at: NSPoint(x: sender.frame.minX, y: sender.frame.minY),
                in: sender.superview)
        }

        private func rebuildMenu() {
            guard let store, let controller, let item else { return }
            let now = Date()
            let sessionReset = now.addingTimeInterval(2 * 3600)
            let weeklyReset = now.addingTimeInterval(2 * 24 * 3600)
            let sessionCapture = now.addingTimeInterval(self.stale ? -3600 : -120)
            let weeklyCapture = now.addingTimeInterval(self.stale ? -12 * 3600 : -3 * 3600)
            var buckets = PlanUtilizationHistoryBuckets()
            buckets.setHistories([
                PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: [
                    .init(capturedAt: now.addingTimeInterval(-2 * 3600), usedPercent: 8, resetsAt: sessionReset),
                    .init(capturedAt: sessionCapture, usedPercent: 42, resetsAt: sessionReset),
                ]),
                PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
                    .init(capturedAt: now.addingTimeInterval(-4 * 24 * 3600), usedPercent: 5, resetsAt: weeklyReset),
                    .init(capturedAt: now.addingTimeInterval(-3 * 24 * 3600), usedPercent: 22, resetsAt: weeklyReset),
                    .init(capturedAt: now.addingTimeInterval(-24 * 3600), usedPercent: 48, resetsAt: weeklyReset),
                    .init(capturedAt: weeklyCapture, usedPercent: 68, resetsAt: weeklyReset),
                ]),
            ], for: nil)
            // Provider-specific by design: the fixture seeds synthetic Codex history without a live snapshot.
            store.planUtilizationHistory[.codex] = buckets
            store.planUtilizationHistoryLoaded = true
            store.planUtilizationHistoryRevision &+= 1
            // There is deliberately no live snapshot: these are explicitly saved captures.
            let menu = NSMenu(title: "Synthetic quota proof")
            menu.autoenablesItems = false
            menu.addItem(NSMenuItem(title: "Synthetic data only", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem(
                title: self.stale ? "Older captures · no live snapshot" : "Session recent · Weekly 3h old",
                action: nil,
                keyEquivalent: ""))
            menu.addItem(.separator())
            // Provider-specific by design: exercise the production Codex Plan Usage submenu.
            if let submenu = controller.makeUsageHistorySubmenu(provider: .codex, width: 400) {
                let entry = NSMenuItem(title: "Plan Usage", action: nil, keyEquivalent: "")
                entry.isEnabled = true
                entry.submenu = submenu
                menu.addItem(entry)
                // Keep the placeholder untouched; the real controller hydrates on submenu open.
            }
            menu.addItem(.separator())
            let toggle = NSMenuItem(title: "Toggle older captures", action: #selector(self.toggle), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            let quit = NSMenuItem(title: "Quit proof", action: #selector(self.quit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            item.menu = menu
            FileHandle.standardOutput.write(Data("quota-proof ready synthetic-only stale=\(self.stale)\n".utf8))
        }

        @objc private func toggle() {
            self.stale.toggle()
            self.rebuildMenu()
        }

        @objc private func quit() {
            NSApplication.shared.terminate(nil)
        }

        func applicationWillTerminate(_ notification: Notification) {
            self.controller?.prepareForAppShutdown()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            // Only the unique synthetic directory created by this process is removed.
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    /// Absent keys cannot fall through to Foundation defaults domains; writes stay in memory.
    private final class ProofDefaults: UserDefaults, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any]

        init(values: [String: Any]) {
            self.values = values
            super.init(suiteName: "QuotaProof-\(UUID().uuidString)")!
        }

        override func object(forKey key: String) -> Any? { self.lock.withLock { self.values[key] } }
        override func set(_ value: Any?, forKey key: String) { self.lock.withLock { self.values[key] = value } }
        override func removeObject(forKey key: String) { self.set(nil as Any?, forKey: key) }
        override func bool(forKey key: String) -> Bool { (self.object(forKey: key) as? NSNumber)?.boolValue ?? false }
        override func integer(forKey key: String) -> Int { (self.object(forKey: key) as? NSNumber)?.intValue ?? 0 }
        override func float(forKey key: String) -> Float { (self.object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
        override func double(forKey key: String) -> Double { (self.object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
        override func string(forKey key: String) -> String? { self.object(forKey: key) as? String }
        override func array(forKey key: String) -> [Any]? { self.object(forKey: key) as? [Any] }
        override func dictionary(forKey key: String) -> [String: Any]? { self.object(forKey: key) as? [String: Any] }
        override func data(forKey key: String) -> Data? { self.object(forKey: key) as? Data }
        override func stringArray(forKey key: String) -> [String]? { self.object(forKey: key) as? [String] }
        override func url(forKey key: String) -> URL? { self.object(forKey: key) as? URL }
        override func set(_ value: Bool, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: Int, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: Float, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: Double, forKey key: String) { self.set(value as Any, forKey: key) }
        override func set(_ value: URL?, forKey key: String) { self.set(value as Any?, forKey: key) }
        override func dictionaryRepresentation() -> [String: Any] { self.lock.withLock { self.values } }
    }
}
#endif
