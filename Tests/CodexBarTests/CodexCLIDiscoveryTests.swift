import Foundation
import Testing
@testable import CodexBarCore

struct CodexCLIDiscoveryTests {
    #if os(macOS)
    @Test(arguments: ["/Applications", "/Users/test/Applications"])
    func `resolves current ChatGPT launcher with bundle validation`(applications: String) {
        let bundle = "\(applications)/ChatGPT.app"
        let launcher = "\(bundle)/Contents/Resources/codex-cli/bin/codex"
        let fm = MockFileManager(executables: [launcher])
        var assessed: [String] = []
        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["PATH": "/missing/bin"],
            loginPATH: nil,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            launchCandidateFilter: { path, fileManager in
                CodexLaunchPreflight.isLaunchCandidateAllowed(
                    path: path,
                    fileManager: fileManager,
                    hasExtendedAttribute: { _, _ in false },
                    spctlAssessment: { path in
                        assessed.append(path)
                        return .init(output: "accepted", exitStatus: 0)
                    },
                    appSignatureIsTrusted: { $0 == bundle },
                    isMachOExecutable: { _ in false })
            },
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == launcher)
        #expect(assessed == [bundle])
    }

    @Test(arguments: ["untrusted", "rejected", "unavailable"])
    func `current ChatGPT launcher still fails closed on untrusted bundle`(failure: String) {
        let launcher = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: launcher,
            fileManager: MockFileManager(executables: [launcher]),
            hasExtendedAttribute: { _, _ in false },
            spctlAssessment: { _ in
                failure == "unavailable" ? nil : .init(
                    output: failure == "rejected" ? "rejected" : "accepted",
                    exitStatus: failure == "rejected" ? 1 : 0)
            },
            appSignatureIsTrusted: { _ in failure != "untrusted" },
            isMachOExecutable: { _ in false })
        #expect(!allowed)
    }

    @Test(arguments: [false, true])
    func `npm payload availability preserves PATH precedence or falls through to ChatGPT`(payloadPresent: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wrapper = root.appendingPathComponent("node_modules/@openai/codex/bin/codex.js")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(
            at: wrapper.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: wrapper)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("codex"), withDestinationURL: wrapper)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let native = root.appendingPathComponent(
            "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex").path
        let shim = bin.appendingPathComponent("codex").path
        var executables: Set<String> = [shim, launcher]
        if payloadPresent { executables.insert(native) }
        let fm = MockFileManager(executables: executables)
        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["PATH": bin.path],
            loginPATH: nil,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            launchCandidateFilter: { path, fileManager in
                CodexLaunchPreflight.isLaunchCandidateAllowed(
                    path: path,
                    fileManager: fileManager,
                    hasExtendedAttribute: { _, _ in false },
                    spctlAssessment: { _ in .init(output: "accepted", exitStatus: 0) },
                    appSignatureIsTrusted: { _ in true },
                    isMachOExecutable: { _ in false })
            },
            fileManager: fm,
            home: root.path)
        #expect(resolved == (payloadPresent ? shim : launcher))
    }

    @Test(arguments: ["nested", "hoisted", "legacy", "missing"], ["bin", "codex"])
    func `npm native payload availability controls wrapper eligibility`(layout: String, directory: String) {
        for (package, triple) in [
            ("codex-darwin-arm64", "aarch64-apple-darwin"),
            ("codex-darwin-x64", "x86_64-apple-darwin"),
        ] {
            let root = "/fixture/node_modules/@openai/codex"
            let wrapper = "\(root)/bin/codex.js"
            let payloadRoot = switch layout {
            case "nested": "\(root)/node_modules/@openai/\(package)"
            case "hoisted": "/fixture/node_modules/@openai/\(package)"
            default: root
            }
            let native = "\(payloadRoot)/vendor/\(triple)/\(directory)/codex"
            let fm = MockFileManager(executables: layout == "missing" ? [wrapper] : [wrapper, native])
            var assessed: [String] = []
            let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
                path: wrapper,
                fileManager: fm,
                hasExtendedAttribute: { _, _ in false },
                spctlAssessment: { path in
                    assessed.append(path)
                    return .init(output: "accepted", exitStatus: 0)
                },
                appSignatureIsTrusted: { _ in false },
                isMachOExecutable: { $0 == native && layout != "missing" })
            #expect(allowed == (layout != "missing"))
            #expect(assessed == (layout == "missing" ? [] : [native]))
        }
    }

    #endif
}

private final class MockFileManager: FileManager {
    private let executables: Set<String>

    init(executables: Set<String>) {
        self.executables = executables
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        self.executables.contains(path)
    }
}
