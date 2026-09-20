import Testing
import Foundation
@testable import CDP

/// Gate for the launch-failure diagnostics on `ChromeLauncher.discoverWebSocketURL`.
///
/// A browser that refuses to start is DEAD, not slow: discovery must report the cause from
/// its stderr (e.g. `Failed to create <profile>/SingletonLock: File exists`) rather than
/// polling out the timeout and blaming the network.
///
/// Hermetic, following `ChromeLauncherTeardownTests`: no Chrome is launched. A `Handle` is
/// built over a host process that has already exited plus a stderr file holding what Chrome
/// would have written, which is exactly the state discovery must recognise.
@Suite(.serialized) struct ChromeLauncherDiscoveryDiagnosticsTests {

    /// Chrome's actual refusal when the profile directory is already held.
    private static let singletonRefusal = """
        [57667:1864854:0728/213340.974037:ERROR:chrome/browser/process_singleton_posix.cc:347] \
        Failed to create /Users/u/Library/Application Support/AlohaJet/ChromeProfile/SingletonLock: \
        File exists (17)
        Failed to create a ProcessSingleton for your profile directory. Aborting now to avoid \
        profile corruption.
        """

    /// Port 1 is privileged and unbound, so a connect attempt is refused immediately and
    /// the poll cannot accidentally succeed against some unrelated listener.
    private static let unservedPort = 1

    /// Builds a handle whose process has already exited, with `stderr` captured.
    private func exitedHandle(stderr: String?) throws -> ChromeLauncher.Handle {
        let userDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-cdp-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)

        var stderrLogURL: URL?
        if let stderr {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("alohajet-chrome-stderr-\(UUID().uuidString).log")
            try Data(stderr.utf8).write(to: url)
            stderrLogURL = url
        }

        // A process that exits on its own, so `isRunning` is false and
        // `terminationStatus` is readable — the state a refusing browser leaves behind.
        let process = Process()
        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "exit", "1"]
        #else
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 1"]
        #endif
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        return ChromeLauncher.Handle(
            process: process, port: Self.unservedPort,
            userDataDir: userDataDir, ownsUserDataDir: true,
            stderrLogURL: stderrLogURL)
    }

    private func launcher() -> ChromeLauncher {
        // Never launched here; discovery is what is under test.
        ChromeLauncher(executablePath: "/nonexistent/browser")
    }

    @Test("a browser that exited is reported as exited, quoting its own stderr")
    func exitedBrowserIsExplained() async throws {
        let handle = try exitedHandle(stderr: Self.singletonRefusal)
        defer { handle.terminate() }

        let error = try await #require(throws: CDPError.self) {
            _ = try await self.launcher().discoverWebSocketURL(
                port: Self.unservedPort, timeout: 10, handle: handle)
        }

        // The message must carry the diagnosis, not just the symptom.
        let message = "\(error)"
        #expect(message.contains("exited without serving"))
        #expect(message.contains("SingletonLock"))
        #expect(message.contains("Aborting now"))
        // The old wording blamed the connection; it must not be what an operator reads.
        #expect(!message.contains("Timed out waiting"))
    }

    @Test("the exit is reported without waiting out the timeout")
    func exitedBrowserFailsFast() async throws {
        let handle = try exitedHandle(stderr: Self.singletonRefusal)
        defer { handle.terminate() }

        let started = Date()
        await #expect(throws: (any Error).self,
                      "discovery unexpectedly succeeded against an unserved port") {
            _ = try await launcher().discoverWebSocketURL(
                port: Self.unservedPort, timeout: 30, handle: handle)
        }
        // Well inside the 30s budget: the point is that a decided failure is not
        // deferred. Generous enough not to measure the machine's mood.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("a still-running browser is still polled to the timeout")
    func liveBrowserKeepsPolling() async throws {
        // Without a handle the caller may not own the browser, so an unserved port is
        // indistinguishable from one that is merely slow: the timeout must still apply.
        let started = Date()
        await #expect(throws: CDPError.self) {
            _ = try await self.launcher().discoverWebSocketURL(
                port: Self.unservedPort, timeout: 1, pollInterval: 0.1)
        }
        #expect(Date().timeIntervalSince(started) >= 1)
    }

    @Test("a missing stderr capture degrades to the exit status alone")
    func exitedBrowserWithoutStderrStillExplained() async throws {
        let handle = try exitedHandle(stderr: nil)
        defer { handle.terminate() }

        let error = try await #require(throws: CDPError.self) {
            _ = try await self.launcher().discoverWebSocketURL(
                port: Self.unservedPort, timeout: 10, handle: handle)
        }
        let message = "\(error)"
        #expect(message.contains("exited without serving"))
        #expect(message.contains("exit status"))
        // No capture, so no stderr clause — and no crash reaching for one.
        #expect(!message.contains("Browser stderr:"))
    }

    @Test("the captured stderr file is removed on terminate")
    func terminateRemovesTheStderrCapture() throws {
        let handle = try exitedHandle(stderr: Self.singletonRefusal)
        let log = try #require(handle.stderrLogURL)
        #expect(FileManager.default.fileExists(atPath: log.path))
        handle.terminate()
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }
}
