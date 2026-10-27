import Testing
import Foundation
@testable import CDP

// A SIGINT or SIGTERM a front end turns into cancellation can land while the browser is still
// starting, and discovery is what is running then. Nothing here serves CDP, so a discovery that
// does not honour cancellation is only stopped by its own 30s timeout.
@Suite("cancelling discovery of a browser that is still starting", .serialized)
struct ChromeLauncherDiscoveryCancellationTests {

    private func cancel(_ discovery: Task<URL, Error>) async throws -> (Result<URL, Error>, TimeInterval) {
        try await Task.sleep(nanoseconds: 500_000_000)
        let cancelled = Date()
        discovery.cancel()
        let result = await discovery.result
        return (result, Date().timeIntervalSince(cancelled))
    }

    @Test("a cancelled discovery stops polling at once")
    func cancelledDiscoveryStops() async throws {
        let launcher = ChromeLauncher(executablePath: "/nonexistent/browser")
        let (result, elapsed) = try await cancel(Task {
            try await launcher.discoverWebSocketURL(port: 1, timeout: 30, pollInterval: 0.1)
        })
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(elapsed < 2, "returned \(elapsed)s after the cancel")
    }

    @Test("a cancelled discovery takes the half-started browser down")
    func cancelledDiscoveryEndsTheBrowser() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-discovery-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // A child spawned from a test worker thread inherits nearly every signal blocked, and
        // `sleep` would wait out terminate()'s escalation to SIGKILL. Chrome empties the mask it
        // inherits at startup, so the stand-in does too.
        let browser = scratch.appendingPathComponent("browser").path
        try """
            #!/usr/bin/perl
            use POSIX;
            sigprocmask(SIG_SETMASK, POSIX::SigSet->new);
            exec "sleep", "60";

            """.write(toFile: browser, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: browser)

        let launcher = ChromeLauncher(executablePath: browser)
        let handle = try launcher.launch(port: 1)
        defer { handle.terminate() }
        let (result, elapsed) = try await cancel(Task {
            try await launcher.discoverWebSocketURL(port: 1, timeout: 30, pollInterval: 0.1, handle: handle)
        })
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(elapsed < 2, "returned \(elapsed)s after the cancel")
        #expect(!handle.process.isRunning, "the browser outlived the discovery that was waiting on it")
        #expect(!FileManager.default.fileExists(atPath: handle.userDataDir.path))
    }
}
