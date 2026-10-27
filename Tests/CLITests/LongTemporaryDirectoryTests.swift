#if os(Linux)
import Foundation
import CDP
import Testing

private nonisolated let browserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

// Chromium on Linux binds its process-singleton socket under `$TMPDIR`, so a TMPDIR past
// ~60 bytes overflowed `sun_path` and every launch died as "exited without serving the CDP
// endpoint" — on a CI runner or a sandbox that nests its temp a few levels deep.
@Suite("a long TMPDIR", .serialized)
struct LongTemporaryDirectoryTests {

    @Test("a browser launches and answers under a TMPDIR too long for its singleton socket")
    func launchesUnderALongTemporaryDirectory() throws {
        let browser = ProcessInfo.processInfo.environment["ALOHAJET_BROWSER"]
            ?? ChromeLauncher.defaultExecutablePath
        guard ChromeLauncher(executablePath: browser).isAvailable else {
            #expect(!browserIsRequired, "no browser at \(browser), and ALOHAJET_REQUIRE_BROWSER is set")
            return
        }
        let long = FileManager.default.temporaryDirectory.appendingPathComponent(
            "alohajet-long-tmpdir-" + String(repeating: "x", count: 72), isDirectory: true)
        try FileManager.default.createDirectory(
            at: long, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: long) }
        #expect(long.path.utf8.count > 80)

        let run = try runCLI(["--launch", "tabs"], environment: ["TMPDIR": long.path], timeout: 60)
        #expect(run.status == 0, "exited \(run.status): \(run.combined)")
        #expect(run.stdout.contains("tab(s) open"), "\(run.combined)")
    }
}
#endif
