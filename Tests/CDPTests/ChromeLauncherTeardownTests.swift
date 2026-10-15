import Testing
import Foundation
import Dispatch
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
    #if os(macOS) || os(Linux)
    @Test func terminateWaitsForProfileWriterAfterBrowserLeaderExits() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-helper-teardown-\(UUID().uuidString)")
        let profile = sandbox.appendingPathComponent("profile")
        let ready = sandbox.appendingPathComponent("ready")
        let release = sandbox.appendingPathComponent("release")
        let wrote = sandbox.appendingPathComponent("wrote")
        let leaderExit = sandbox.appendingPathComponent("leader-exit")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // A real descendant remains in the browser's private process group after
        // its leader exits. It can still write (and recreate) the profile until
        // released, just like Chrome's utility processes during shutdown.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
            trap '' TERM INT
            /bin/sh -c '
                trap "" TERM INT
                touch "$1"
                while [ ! -f "$2" ]; do sleep 0.01; done
                mkdir -p "$3"
                echo late > "$3/late-write"
                touch "$4"
            ' helper "$1" "$2" "$3" "$4" &
            while [ ! -f "$5" ]; do sleep 0.01; done
            """, "browser", ready.path, release.path, profile.path, wrote.path, leaderExit.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handle = ChromeLauncher.Handle(process: process, port: 0, userDataDir: profile, ownsUserDataDir: true)
        // Always release the helper, even when a precondition/assertion fails.
        defer {
            _ = FileManager.default.createFile(atPath: leaderExit.path, contents: nil)
            _ = FileManager.default.createFile(atPath: release.path, contents: nil)
            handle.terminate()
        }
        func waitFor(_ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            return predicate()
        }
        try #require(waitFor { FileManager.default.fileExists(atPath: ready.path) })
        // Release the leader explicitly: the regression concerns descendant
        // lifetime after leader exit, independently of inherited signal masks.
        _ = FileManager.default.createFile(atPath: leaderExit.path, contents: nil)
        try #require(waitFor {
            if !process.isRunning { return true }
            #if os(Linux)
            // Corelibs keeps isRunning true for a zombie leader until its group
            // exits. Confirm actual leader exit without releasing the helper.
            let status = try? String(contentsOfFile: "/proc/\(process.processIdentifier)/status", encoding: .utf8)
            return status?.split(separator: "\n").first { $0.hasPrefix("State:") }?.contains("Z") == true
            #else
            return false
            #endif
        })
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            handle.terminate()
            completed.signal()
        }
        let earlyCompletion = completed.wait(timeout: .now() + 0.1)
        #expect(earlyCompletion == .timedOut, "teardown must await the live profile writer, not just its exited leader")
        #expect(FileManager.default.fileExists(atPath: profile.path), "profile removal must follow helper exit")
        _ = FileManager.default.createFile(atPath: release.path, contents: nil)
        if earlyCompletion == .timedOut {
            try #require(completed.wait(timeout: .now() + 5) == .success)
        }
        #expect(waitFor { FileManager.default.fileExists(atPath: wrote.path) }, "control: the helper actually wrote after the leader exited")
        #expect(!FileManager.default.fileExists(atPath: profile.path), "the late profile write must also be cleaned up")
        #expect(!process.isRunning)
    }
    #endif

}
