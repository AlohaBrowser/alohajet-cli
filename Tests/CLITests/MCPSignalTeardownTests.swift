import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Dispatch
import CDP
import ToolABI
import Testing

// A signalled `alohajet mcp --launch` must DIE. Not "kill the browser and keep
// breathing" — die. `--launch` is the lane whose browser the server OWNS: the default
// lane joins the shared browser, which outlives every command on purpose and is ended
// by `alohajet quit` alone, so there is nothing there for a signal to reap.
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
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var completed = false
        let started = DispatchTime.now().uptimeNanoseconds
        let browserStderr = sandbox.appendingPathComponent("browser.stderr")
        let browserPID = sandbox.appendingPathComponent("browser.pid")
        let cliStderr = sandbox.appendingPathComponent("cli.stderr")
        func phase(_ name: String) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            diagnostic("ending=\(ending) phase=\(name) elapsed=\(elapsed)s")
        }
        defer {
            phase(completed ? "complete" : "failed-retained-at=\(sandbox.path)")
            if completed {
                try? FileManager.default.removeItem(at: sandbox)
            } else {
                // Only files created by this fixture; never look for a host log.
                for url in [cliStderr, browserStderr] {
                    let tail = ((try? Data(contentsOf: url)) ?? Data()).suffix(4_096)
                    diagnostic("\(url.lastPathComponent): \(String(decoding: tail, as: UTF8.self))")
                }
            }
        }

        let stdin = Pipe(), stdout = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--launch", "mcp"]
        var environment = ProcessInfo.processInfo.environment
        // The launched browser's throwaway profile lands here, which is how the checks
        // below can name it. Only honoured because the CLI reads `$TMPDIR` — see
        // `ToolABI.temporaryDirectory`.
        let browserTemp = sandbox.appendingPathComponent("browser-temp")
        try FileManager.default.createDirectory(at: browserTemp, withIntermediateDirectories: true)
        environment["TMPDIR"] = browserTemp.path
        for key in ["BASH_ENV", "ENV", "ZDOTDIR"] { environment.removeValue(forKey: key) }
        // exec preserves the actual browser PID/signals. Redirect at its owned launch
        // boundary so production cleanup cannot unlink the sole diagnostic copy.
        // The fixture opens only about:blank, with a throwaway profile.
        let browserExecutable = environment["ALOHAJET_BROWSER"] ?? ChromeLauncher.defaultExecutablePath
        if ChromeLauncher(executablePath: browserExecutable).isAvailable {
            let wrapper = sandbox.appendingPathComponent("chrome-with-diagnostics")
            func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            let script = "#!/bin/sh\numask 077\nprintf '%s\\n' \"$$\" > \(quoted(browserPID.path))\nexec \(quoted(browserExecutable)) \"$@\" 2> \(quoted(browserStderr.path))\n"
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            environment["ALOHAJET_BROWSER"] = wrapper.path
        }
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        FileManager.default.createFile(atPath: cliStderr.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let stderrSink = try FileHandle(forWritingTo: cliStderr)
        defer { try? stderrSink.close() }
        process.standardError = stderrSink
        try process.run()
        phase("cli-started-pid=\(process.processIdentifier)")
        let progress = FixtureProgress(process: process, browserPID: browserPID, started: started)
        defer {
            progress.stop()
            // Also reap our own CLI on an early #require failure.
            if process.isRunning {
                process.terminate()
                if !waitForExit(process, within: 10) {
                    kill(process.processIdentifier, SIGKILL)
                    _ = waitForExit(process, within: 2)
                }
            }
            phase(process.isRunning ? "cli-still-running" : "cli-exit-status=\(process.terminationStatus)")
        }

        let reader = LineReader(stdout.fileHandleForReading)
        func send(_ json: String) { try? stdin.fileHandleForWriting.write(contentsOf: Data((json + "\n").utf8)) }

        phase("initialize-send")
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        _ = try #require(reader.line(within: 15), "no answer to initialize")

        phase("initialize-received")

        // The browser is built on the first tools/call, and only then is the signal
        // reaper installed. A server with no browser has nothing to hang on.
        phase("tools-call-send")
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"manage_tabs","arguments":{"action":"open","url":"about:blank"}}}"#)
        let answer = try #require(reader.line(within: 90), "no answer to tools/call")
        phase("tools-call-received")
        if answer.contains("Could not reach a browser") {
            process.terminate()
            _ = waitForExit(process, within: 10)
            #expect(browserIsRequired == false,
                    "ALOHAJET_REQUIRE_BROWSER is set, so a missing browser is a failure: \(answer)")
            return
        }

        let profiles = launchedProfiles(in: browserTemp)
        #expect(!profiles.isEmpty, "the tools/call launched no browser profile under \(sandbox.path)")

        phase("ending-send")
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
        phase("exit-observed-status=\(process.terminationStatus)")
        #expect(process.terminationStatus == expectedStatus)
        let profilesGone = launchedProfiles(in: browserTemp).isEmpty
        #expect(profilesGone, "the throwaway profile outlived the server")
        completed = !profiles.isEmpty && process.terminationStatus == expectedStatus && profilesGone
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
        if (try? killer.run()) != nil, !waitForExit(killer, within: 5) {
            kill(killer.processIdentifier, SIGKILL)
            _ = waitForExit(killer, within: 2)
        }
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

/// Progress from a private timer queue remains visible when MainActor is occupied.
/// Only one actor probe may be pending, and stopping cancels further probes.
private final class FixtureProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var pending = false
    private var probe: Task<Void, Never>?
    private var lastAck: UInt64
    private let timer: DispatchSourceTimer

    init(process: Process, browserPID: URL, started: UInt64) {
        lastAck = started
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mcp-fixture-progress"))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.stopped else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let pid = (try? String(contentsOf: browserPID, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let browserAlive = pid.map { kill($0, 0) == 0 || errno == EPERM }
            diagnostic("progress elapsed=\(Double(now - started) / 1e9)s cliPID=\(process.processIdentifier) running=\(process.isRunning) ownBrowserPID=\(String(describing: pid)) alive=\(String(describing: browserAlive)) mainActorAckAge=\(Double(now - self.lastAck) / 1e9)s")
            if !self.pending {
                self.pending = true
                self.probe = Task { @MainActor [weak self] in
                    guard !Task.isCancelled else { return }
                    self?.acknowledge()
                }
            }
        }
        timer.resume()
    }

    private func acknowledge() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        lastAck = DispatchTime.now().uptimeNanoseconds
        pending = false
        probe = nil
    }

    func stop() {
        lock.lock()
        stopped = true
        let activeProbe = probe
        probe = nil
        lock.unlock()
        activeProbe?.cancel()
        timer.cancel()
    }
}

private func diagnostic(_ message: String) {
    writeToStandardError("[mcp-fixture] " + message + "\n")
}
