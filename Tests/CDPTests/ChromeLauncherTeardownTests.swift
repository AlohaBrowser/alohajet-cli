import Testing
import Foundation
@testable import CDP
import ToolABI

/// Cross-platform teardown hardening regression gate for
/// `ChromeLauncher.Handle.terminate()`.
///
/// Regression note: a wedged downloaded Chromium must be reaped on EVERY
/// platform, and neither the temporary `userDataDir` nor the downloaded binary
/// may leak. These tests pin two properties of `terminate()` that the
/// hardening refactor must preserve:
///
///   1. `terminate()` removes the temporary `userDataDir` (no profile leak), and
///   2. `terminate()` is idempotent — calling it twice is safe and still leaves
///      the `userDataDir` gone.
///
/// To stay hermetic (no Chrome dependency) the tests build a `Handle` over a
/// trivially-available host process and a real temporary directory, then drive
/// `terminate()` exactly as production does. The Windows hard-kill branch is
/// compile-guarded behind `#if os(Windows)`; on the macOS/Linux CI suite it is
/// excluded from the build, so these tests verify the always-present cleanup
/// and idempotency contract that the Windows branch must also honour.
@Suite(.serialized) final class ChromeLauncherTeardownTests {

    /// Spawn a short-lived host process and pair it with a freshly-created
    /// temporary `userDataDir`, mirroring what `ChromeLauncher.launch` produces.
    private func makeHandle() throws -> (handle: ChromeLauncher.Handle, dir: URL) {
        let userDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-cdp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: userDataDir,
            withIntermediateDirectories: true
        )
        // Drop a file inside so we are sure the *directory tree* is removed.
        let marker = userDataDir.appendingPathComponent("Default", isDirectory: false)
        try Data("profile".utf8).write(to: marker)

        let process = Process()
        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/C", "ping", "127.0.0.1", "-n", "30"]
        #else
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        #endif
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let handle = ChromeLauncher.Handle(
            process: process,
            port: 0,
            userDataDir: userDataDir,
            // The test owns the temp userDataDir it created and asserts terminate()
            // removes it, so the handle must own it (post-#6fdd971 `ownsUserDataDir`).
            ownsUserDataDir: true
        )
        return (handle, userDataDir)
    }

    @Test func testTerminateRemovesUserDataDir() throws {
        let (handle, dir) = try makeHandle()
        #expect(
            FileManager.default.fileExists(atPath: dir.path),
            "Precondition: userDataDir should exist before terminate()"
        )

        handle.terminate()

        #expect(
            !FileManager.default.fileExists(atPath: dir.path),
            "terminate() must remove the temporary userDataDir so it cannot leak"
        )
        #expect(
            !handle.process.isRunning,
            "terminate() must reap the launched child on every platform"
        )
    }

    @Test func testTerminateIsIdempotent() throws {
        let (handle, dir) = try makeHandle()

        handle.terminate()
        // A second call must be safe — no crash, no throw — and must leave the
        // userDataDir gone. This is the contract a wedged downloaded Chromium
        // teardown relies on across repeated cleanup attempts.
        handle.terminate()

        #expect(
            !FileManager.default.fileExists(atPath: dir.path),
            "userDataDir must stay removed after a repeated terminate()"
        )
        #expect(
            !handle.process.isRunning,
            "process must remain reaped after a repeated terminate()"
        )
    }
}
