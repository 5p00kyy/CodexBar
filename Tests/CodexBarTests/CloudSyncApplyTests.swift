import CloudKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CloudSyncApplyTests {
    enum Interruption: CaseIterable {
        case cancel, stop, supersede, schemaPause
    }

    @Test(arguments: [SyncRecordType.providerIntent, .preferences], [1, 2])
    func `interrupted apply cannot overwrite settings or sync bookkeeping`(
        type: SyncRecordType,
        suspension: Int) async throws
    {
        for interruption in Interruption.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let settings = testSettingsStore(
                suiteName: "CloudSyncApplyTests",
                userDefaults: InMemoryUserDefaults(),
                keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
            let persistence = CloudSyncPersistence(fileURL: directory.appendingPathComponent("sync.json"))
            let state = CloudSyncState()
            let gate = ApplyGate(suspension: suspension)
            let engine = CloudSyncEngine(
                settings: settings,
                state: state,
                persistence: persistence,
                initialConfiguration: settings.configSnapshot,
                initialPreferences: settings.syncedPreferences,
                beforeApply: { await gate.suspend() })
            let original = try self.record(type, settings: settings, changed: false, editCount: 2)
            let stale = try self.record(type, settings: settings, changed: true, editCount: 1)
            let oldConfig = settings.configSnapshot
            let oldPreferences = settings.syncedPreferences
            try settings.configStore.save(oldConfig)

            let task = Task { await engine.applyFetchedRecords([stale]) }
            await gate.waitUntilSuspended()
            switch interruption {
            case .cancel: task.cancel()
            case .stop: await engine.stop()
            case .supersede: await engine.applyFetchedRecords([original])
            case .schemaPause: state.status.needsAppUpdate = true
            }
            await gate.resume()
            await task.value

            #expect(settings.configSnapshot.providerConfig(for: .claude)?.extrasEnabled ==
                oldConfig.providerConfig(for: .claude)?.extrasEnabled)
            #expect(settings.hidePersonalInfo == oldPreferences.hidePersonalInfo)
            let savedConfig = try #require(try settings.configStore.load())
            #expect(savedConfig.providerConfig(for: .claude)?.extrasEnabled ==
                oldConfig.providerConfig(for: .claude)?.extrasEnabled)
            // These notifications must not mistake unchanged settings for a new local edit.
            engine.localUserConfigurationDidChange(oldConfig)
            engine.localUserPreferencesDidChange(oldPreferences)
            let saved = persistence.load()
            #expect(saved.dirtyProviders.isEmpty)
            #expect(!saved.preferencesDirty)
            #expect(saved.recordMetadata[stale.recordID.recordName]?.editCount ==
                (interruption == .supersede ? 2 : nil))
            #expect(state.status.lastError == nil)
        }
    }

    @Test
    func `already cancelled replacement leaves the active apply valid`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = testSettingsStore(suiteName: "CloudSyncApplyTests", userDefaults: InMemoryUserDefaults())
        let gate = ApplyGate(suspension: 1)
        let engine = CloudSyncEngine(
            settings: settings,
            state: CloudSyncState(),
            persistence: CloudSyncPersistence(fileURL: directory.appendingPathComponent("sync.json")),
            beforeApply: { await gate.suspend() })
        let original = settings.hidePersonalInfo
        let record = try self.record(.preferences, settings: settings, changed: true, editCount: 1)
        let active = Task { await engine.applyFetchedRecords([record]) }
        await gate.waitUntilSuspended()
        let replacement = Task { await engine.applyFetchedRecords([]) }
        replacement.cancel()
        await replacement.value
        await gate.resume()
        await active.value

        #expect(settings.hidePersonalInfo != original)
    }

    private func record(
        _ type: SyncRecordType, settings: SettingsStore, changed: Bool, editCount: Int) throws -> CKRecord
    {
        let name: String
        let payload: String
        if type == .providerIntent {
            var config = try #require(settings.configSnapshot.providerConfig(for: .claude))
            if changed { config.extrasEnabled = !(config.extrasEnabled ?? false) }
            name = ProviderIntentPayload.recordName(for: .claude)
            payload = try CanonicalSyncJSON.string(ProviderIntentPayload(config: config))
        } else {
            var preferences = settings.syncedPreferences
            if changed { preferences.hidePersonalInfo.toggle() }
            name = PreferencesSyncPayload.recordName
            payload = try CanonicalSyncJSON.string(PreferencesSyncPayload(preferences: preferences))
        }
        let record = CKRecord(recordType: type.rawValue, recordID: CKRecord.ID(
            recordName: name, zoneID: CloudSyncEngine.zoneID))
        record["payload"] = payload as CKRecordValue
        record["editCount"] = editCount as CKRecordValue
        return record
    }
}

private actor ApplyGate {
    private var remaining: Int
    private var suspended = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(suspension: Int) {
        self.remaining = suspension
    }

    func suspend() async {
        self.remaining -= 1
        guard self.remaining == 0 else { return }
        await withCheckedContinuation { continuation in
            self.release = continuation
            self.suspended = true
            self.arrival?.resume()
            self.arrival = nil
        }
    }

    func waitUntilSuspended() async {
        guard !self.suspended else { return }
        await withCheckedContinuation { self.arrival = $0 }
    }

    func resume() {
        self.release?.resume()
        self.release = nil
    }
}
