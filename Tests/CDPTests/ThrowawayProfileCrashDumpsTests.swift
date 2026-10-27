#if os(Linux)
import Testing
import Foundation
import Glibc
@testable import CDP

private nonisolated let browserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let browserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

// Chrome's crash handler keeps its database under the DEFAULT user-data dir whatever
// `--user-data-dir` says, so a throwaway-profile run wrote into
// `~/.config/google-chrome/Crash Reports`, the user's own Chrome tree. Read off the live
// handler's argv, which is the only place the path it actually uses is visible.
@Suite("a throwaway profile's crash dumps", .serialized,
       .enabled(if: browserIsAvailable || browserIsRequired))
struct ThrowawayProfileCrashDumpsTests {

    @Test("the crash handler of a throwaway-profile browser writes inside that profile")
    func crashHandlerWritesInsideTheProfile() async throws {
        try #require(browserIsAvailable,
                     "no browser at \(ChromeLauncher().executablePath), and ALOHAJET_REQUIRE_BROWSER is set")
        let launcher = ChromeLauncher()
        let port = try freeLoopbackPort()
        let handle = try launcher.launch(port: port)
        defer { handle.terminate() }
        _ = try await launcher.discoverWebSocketURL(port: port, timeout: 30, handle: handle)

        let databases = crashHandlerDatabases(forProfile: handle.userDataDir.path)
        #expect(!databases.isEmpty, "found no crash handler for \(handle.userDataDir.path)")
        let expected = handle.userDataDir.appendingPathComponent("Crash Reports").path
        #expect(databases == [expected])
    }

    /// The `--database` of every crash handler a browser on `profile` reports to. The
    /// handler's own argv does not name the profile; its clients carry its pid.
    private func crashHandlerDatabases(forProfile profile: String) -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        let handlers = entries.compactMap(Int32.init).flatMap { pid -> [String] in
            // Chrome rewrites its processes' argv into one space-joined title.
            let title = commandLine(of: pid).joined(separator: " ")
            guard title.contains("--user-data-dir=\(profile)") else { return [] }
            return title.split(separator: " ").compactMap { String($0).dropPrefix("--crashpad-handler-pid=") }
        }
        return Set(Set(handlers).compactMap(Int32.init).flatMap { pid in
            commandLine(of: pid).compactMap { $0.dropPrefix("--database=") }
        })
    }

    private func commandLine(of pid: Int32) -> [String] {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return [] }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        try #require(bound)
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
#endif
