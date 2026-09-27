#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Stops processes that a finished CLI left behind in a private working directory.
///
/// `agy -p /usage` starts the user's MCP servers with that directory as their cwd, then
/// exits. Servers that call `setsid` are no longer children and are not in the CLI's
/// process group, so they survive and keep a core busy. Matching the directory still finds them.
enum ProcessWorkingDirectoryReaper {
    static func terminateProcesses(in directory: URL) {
        let target = Self.standardizedPath(directory.path)
        guard !target.isEmpty, target != "/" else { return }
        let matches = self.processIDs(inCurrentDirectory: target)
        guard !matches.isEmpty else { return }
        for pid in matches {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if matches.allSatisfy({ kill($0, 0) != 0 }) { return }
            usleep(50_000)
        }
        for pid in matches where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    static func processIDs(inCurrentDirectory directory: String) -> [pid_t] {
        let target = Self.standardizedPath(directory)
        guard !target.isEmpty else { return [] }
        let selfPID = pid_t(getpid())
        return self.allProcessIDs().filter { pid in
            pid > 0 && pid != selfPID && self.currentDirectory(of: pid) == target
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func allProcessIDs() -> [pid_t] {
        #if canImport(Darwin)
        let bufferCount = proc_listallpids(nil, 0)
        guard bufferCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferCount) + 32)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let written = proc_listallpids(&pids, byteCount)
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written)))
        #else
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return names.compactMap { pid_t($0) }
        #endif
    }

    private static func currentDirectory(of pid: pid_t) -> String? {
        #if canImport(Darwin)
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_vnodepathinfo>.stride))
        guard size == Int32(MemoryLayout<proc_vnodepathinfo>.stride) else { return nil }
        var pathBuffer = info.pvi_cdir.vip_path
        let pathCapacity = MemoryLayout.size(ofValue: pathBuffer)
        let path = withUnsafePointer(to: &pathBuffer) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                String(cString: $0)
            }
        }
        guard !path.isEmpty else { return nil }
        return Self.standardizedPath(path)
        #else
        let link = "/proc/\(pid)/cwd"
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
              !destination.isEmpty
        else { return nil }
        return Self.standardizedPath(destination)
        #endif
    }
}
