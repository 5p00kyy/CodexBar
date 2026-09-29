import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIWorkspaceTrustTests {
    @Test
    func `captured trust dialog preselects No and is answered by moving to the trust option`() throws {
        let dialog = try ClaudeCLIScreenProbeTests.capture("workspace-trust-dialog")
        let screen = ClaudeCLIScreen.render(dialog)
        let lines = screen.components(separatedBy: "\n")
        #expect(lines.contains(" ❯ No, exit"))
        #expect(lines.contains("   Yes, I trust this folder"))
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: screen, acceptsTrust: true) == "\u{1b}[B")
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: screen, acceptsTrust: false) == "\u{1b}")

        let redrawn = try ClaudeCLIScreen.render(dialog + ClaudeCLIScreenProbeTests.capture(
            "workspace-trust-select-down"))
        let redrawnLines = redrawn.components(separatedBy: "\n")
        #expect(redrawnLines.contains("   No, exit"))
        #expect(redrawnLines.contains(" ❯ Yes, I trust this folder"))
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: redrawn, acceptsTrust: true) == "\r")
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: redrawn, acceptsTrust: false) == "\u{1b}")
    }

    @Test(arguments: [
        (" Quick safety check:\n\n ❯ Yes, I trust this folder\n   No, exit\n\n Enter to confirm", "\r"),
        (" Quick safety check:\n\n   Yes, I trust this folder\n ❯ No, exit\n\n Enter to confirm", "\u{1b}[A"),
        (" Quick safety check:\n\n ❯ No, exit\n   Cancel\n   Yes, I trust this folder", "\u{1b}[B"),
    ])
    func `trust option is reached from either side before it is confirmed`(screen: String, expected: String) {
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: screen, acceptsTrust: true) == expected)
    }

    @Test(arguments: [
        "",
        " Do you trust the files in this folder?\n\n ❯ 1. Yes, proceed\n   2. No, exit",
        "────\n❯ \n────\n  ? for shortcuts",
    ])
    func `screens without the trust dialog send no keys`(screen: String) {
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: screen, acceptsTrust: true) == nil)
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: screen, acceptsTrust: false) == nil)
    }

    @Test(arguments: [
        " Quick safety check:\n\n   No, exit\n   Yes, I trust this folder\n\n Enter to confirm",
        " ❯ Quick safety check:\n\n   No, exit\n   Yes, I trust this folder",
    ])
    func `trust dialog without a marked option is never confirmed`(screen: String) {
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: screen, acceptsTrust: true) == nil)
        #expect(ClaudeCLISession.workspaceTrustKeys(onScreen: screen, acceptsTrust: false) == "\u{1b}")
    }

    @Test
    func `only the dedicated probe directory accepts workspace trust`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-probe-trust-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dedicated = root.appendingPathComponent("ClaudeProbe", isDirectory: true)
        ClaudeStatusProbe.$dedicatedProbeDirectoryOverrideForTesting.withValue(dedicated) {
            #expect(ClaudeStatusProbe.probeWorkingDirectoryURL() == dedicated)
            #expect(ClaudeStatusProbe.isDedicatedProbeWorkingDirectory(dedicated))
            #expect(!ClaudeStatusProbe.isDedicatedProbeWorkingDirectory(root))
        }
        // When the dedicated directory cannot be created, probes fall back to the shared temporary directory.
        let unavailable = URL(fileURLWithPath: "/dev/null/CodexBar/ClaudeProbe", isDirectory: true)
        ClaudeStatusProbe.$dedicatedProbeDirectoryOverrideForTesting.withValue(unavailable) {
            let fallback = ClaudeStatusProbe.probeWorkingDirectoryURL()
            #expect(fallback == FileManager.default.temporaryDirectory)
            #expect(!ClaudeStatusProbe.isDedicatedProbeWorkingDirectory(fallback))
        }
        let legacyPrompt = "Do you trust the files in this folder?"
        #expect(ClaudeCLISession.promptSends(acceptsTrust: true)[legacyPrompt] == "y\r")
        #expect(ClaudeCLISession.promptSends(acceptsTrust: false)[legacyPrompt] == nil)
    }

    @Test
    func `fresh probe session trusts its dedicated directory before typing the command`() async throws {
        let directory = try Self.makeFakeClaude()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probeDirectory = directory.appendingPathComponent("ClaudeProbe", isDirectory: true)
        try await ClaudeStatusProbe.$dedicatedProbeDirectoryOverrideForTesting.withValue(probeDirectory) {
            let session = ClaudeCLISession()
            do {
                let status = try await Self.captureStatus(session: session, directory: directory)
                await session.reset()
                #expect(status.contains("Account: trusted"))
            } catch {
                print("Synthetic CLI keys:\n" + Self.keysLog(in: directory))
                await session.reset()
                throw error
            }
        }
        #expect(Self.keysLog(in: directory) == """
        key:[B
        confirm:yes
        command:/status

        """)
    }

    @Test
    func `probe session outside its dedicated directory cancels the trust dialog`() async throws {
        let directory = try Self.makeFakeClaude()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probeDirectory = directory.appendingPathComponent("ClaudeProbe", isDirectory: true)
        let error = await ClaudeStatusProbe.$dedicatedProbeDirectoryOverrideForTesting.withValue(probeDirectory) {
            // Like the temporary-directory fallback, the launch directory is not the dedicated probe directory.
            let session = ClaudeCLISession(workingDirectory: directory)
            let thrown = await #expect(throws: ClaudeCLISession.SessionError.self) {
                try await Self.captureStatus(session: session, directory: directory)
            }
            await session.reset()
            return thrown
        }
        #expect(error.map { String(describing: $0) } == "processExited")
        #expect(Self.keysLog(in: directory) == "cancel\n")
    }

    private static func captureStatus(session: ClaudeCLISession, directory: URL) async throws -> String {
        try await session.capture(
            subcommand: "/status",
            binary: directory.appendingPathComponent("fake-claude").path,
            accountScope: "synthetic-account",
            timeout: 5,
            environment: [
                "HOME": directory.path,
                "CLAUDE_CONFIG_DIR": directory.path,
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": directory.path,
                "CODEXBAR_DISABLE_CLAUDE_WATCHDOG": "1",
            ],
            idleTimeout: nil,
            stopOnSubstrings: ["DONE"],
            settleAfterStop: 0)
    }

    private static func keysLog(in directory: URL) -> String {
        (try? String(contentsOf: directory.appendingPathComponent("keys.log"), encoding: .utf8)) ?? "<none>"
    }

    /// Replays the captured Claude Code 2.1.282 frames: Enter on the preselected "No, exit" quits with status 1, and
    /// Escape cancels the dialog with status 0.
    private static func makeFakeClaude() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-workspace-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["workspace-trust-dialog", "workspace-trust-select-down"] {
            try Data(ClaudeCLIScreenProbeTests.capture(name).utf8)
                .write(to: directory.appendingPathComponent("\(name).ansi"))
        }
        let binary = directory.appendingPathComponent("fake-claude")
        let script = #"""
        #!/bin/bash
        /bin/stty raw -echo -icrnl
        /bin/cat "$HOME/workspace-trust-dialog.ansi"
        selected=no
        while IFS= read -r -n 1 key; do
          case "$key" in
            $'\e')
              key=''
              IFS= read -r -t 1 -n 2 key
              if [[ -z "$key" ]]; then
                printf 'cancel\n' >> "$HOME/keys.log"
                exit 0
              fi
              printf 'key:%s\n' "$key" >> "$HOME/keys.log"
              if [[ "$key" == '[B' && "$selected" == no ]]; then
                selected=yes
                /bin/cat "$HOME/workspace-trust-select-down.ansi"
              fi
              ;;
            # read -n 1 reports a newline as an empty key.
            $'\r'|'')
              printf 'confirm:%s\n' "$selected" >> "$HOME/keys.log"
              [[ "$selected" == yes ]] || exit 1
              break
              ;;
          esac
        done
        printf 'ready\r\n'
        command=''
        while IFS= read -r -n 1 key; do
          case "$key" in
            $'\r'|'')
              [[ "$command" == /exit ]] && exit 0
              printf 'command:%s\n' "$command" >> "$HOME/keys.log"
              [[ "$command" == /status ]] && printf 'Account: trusted\r\nDONE\r\n'
              command=''
              ;;
            *) command+="$key" ;;
          esac
        done
        """#
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return directory
    }
}
