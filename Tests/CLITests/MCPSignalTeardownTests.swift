import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Dispatch
import Testing

// A signalled `alohajet mcp` must DIE. Not "kill the browser and keep breathing" — die.
//
// The acceptance test this replaces checked the browser and the profile were gone and
// went green while the server itself hung forever: `browser.terminate()` ran, and the
// next line, `fflush(NULL)`, deadlocked on the `FILE` lock the stdin reader holds inside
// `getdelim` for as long as the host stays quiet. An MCP host that signals its server
// rather than closing the pipe waited on a process that was never going to exit. So the
// assertion below is the EXIT — status and wall clock — with the browser and profile
// checks kept, and it is run for both endings a host can produce: a signal, and EOF.

/// `true` when the tools/call answered with the launcher's "no browser" refusal rather
/// than a tab. The suite skips on that unless CI demands a browser, matching
/// `RealBrowserE2ETests`.
private nonisolated let browserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

@Suite("mcp signal teardown", .serialized)
struct MCPSignalTeardownTests {

    @Test func sigtermExitsAndTakesTheBrowserWithIt() throws {
        try teardown(ending: .signal(SIGTERM), expectedStatus: 128 + SIGTERM)
    }

    @Test func sigintExitsAndTakesTheBrowserWithIt() throws {
        try teardown(ending: .signal(SIGINT), expectedStatus: 128 + SIGINT)
    }

    @Test func closingStdinExitsAndTakesTheBrowserWithIt() throws {
        try teardown(ending: .eof, expectedStatus: 0)
    }

    private enum Ending {
        case signal(Int32)
        case eof
    }

    private func teardown(ending: Ending, expectedStatus: Int32) throws {
        // This test writes to a child it has just signalled, so the write can land on a
        // pipe whose reader is already gone. On Linux the default SIGPIPE disposition
        // then kills the TEST process — reported as "Exited with unexpected signal code
        // 13", taking the whole CLITests target with it — and `try?` cannot catch a
        // signal. Darwin never showed it, and neither did CI, because the package did
        // not compile on Linux until now and so these tests had never once run there.
        signal(SIGPIPE, SIG_IGN)

        let binary = try #require(alohajetBinary, "alohajet binary not found next to the test runner")
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-mcp-signal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let stdin = Pipe(), stdout = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        // The launched browser's throwaway profile lands here, which is how the checks
        // below can name it. Only honoured because the CLI reads `$TMPDIR` — see
        // `ToolABI.temporaryDirectory`.
        environment["TMPDIR"] = sandbox.path
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        let reader = LineReader(stdout.fileHandleForReading)
        func send(_ json: String) { try? stdin.fileHandleForWriting.write(contentsOf: Data((json + "\n").utf8)) }

        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        _ = try #require(reader.line(within: 15), "no answer to initialize")

        // The browser is built on the first tools/call, and only then is the signal
        // reaper installed. A server with no browser has nothing to hang on.
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"manage_tabs","arguments":{"action":"open","url":"about:blank"}}}"#)
        let answer = try #require(reader.line(within: 90), "no answer to tools/call")
        if answer.contains("Could not reach a browser") {
            process.terminate()
            _ = waitForExit(process, within: 10)
            #expect(browserIsRequired == false,
                    "ALOHAJET_REQUIRE_BROWSER is set, so a missing browser is a failure: \(answer)")
            return
        }

        let profiles = launchedProfiles(in: sandbox)
        #expect(!profiles.isEmpty, "the tools/call launched no browser profile under \(sandbox.path)")

        switch ending {
        case .signal(let number): kill(process.processIdentifier, number)
        case .eof: try? stdin.fileHandleForWriting.close()
        }

        // THE ASSERTION. Twenty seconds is two orders of magnitude over the measured
        // teardown (0.15s signalled, 0.25s at EOF) and still finite, which "hangs
        // forever" is not. The margin is for the EOF ending, which reaps the browser
        // gracefully — `terminate()` alone may spend 7s escalating on a loaded machine.
        guard waitForExit(process, within: 20) else {
            kill(process.processIdentifier, SIGKILL)
            for profile in profiles { pkill(matching: profile.path) }
            Issue.record("alohajet mcp did not exit within 20s of \(ending)")
            return
        }
        #expect(process.terminationStatus == expectedStatus)
        #expect(launchedProfiles(in: sandbox).isEmpty, "the throwaway profile outlived the server")
    }

    private func launchedProfiles(in sandbox: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) ?? []
        return names.filter { $0.hasPrefix("alohajet-cdp-") }
            .map { sandbox.appendingPathComponent($0, isDirectory: true) }
    }

    /// A wait with a deadline, POLLED — the same shape as `ChromeLauncher.waitForExit`,
    /// and for the same reason twice over. `waitUntilExit()` blocks, and a server that
    /// never exits is precisely the defect under test, so the wait has to be able to give
    /// up. And `waitUntilExit()` is itself unreliable here: measured, on roughly one full
    /// `swift test` in ten, it never returned for a child that had ALREADY exited —
    /// captured at the deadline as `isRunning=false kill0=false status=0`, i.e. the
    /// process was gone and reaped while the wait sat there. Foundation loses the
    /// termination wakeup when many `Process`es are spawned and reaped at once, which is
    /// exactly what the rest of this suite does. `isRunning` reads the reaped state
    /// directly and cannot miss it.
    private func waitForExit(_ process: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    /// Best effort: kill a browser left behind by a server that failed to reap it, found
    /// by the `--user-data-dir` it was launched with.
    private func pkill(matching pattern: String) {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", pattern]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
    }
}

/// Newline-delimited reads off a pipe, with a deadline. A blocking `read` on the test
/// thread would wedge the run on the very failure this file exists to catch, so the
/// reading happens on a thread and the test polls what has landed.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []

    init(_ handle: FileHandle) {
        Thread { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                lock.lock()
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                lock.unlock()
            }
        }.start()
    }

    func line(within seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            lock.lock()
            let next = lines.isEmpty ? nil : lines.removeFirst()
            lock.unlock()
            if let next { return next }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return nil
    }
}
