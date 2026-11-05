import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `alohajet mcp --endpoint <url>` as a host runs it: stdin stays open while the host waits, the
/// host writes a frame whenever it likes, and it may close stdin or signal the relay at any
/// point. `runCLI` feeds stdin from a file, which is at its end before the first frame is read,
/// so none of that can be expressed there.
///
/// stdin is a pipe written with `write(2)` (see `BinaryUnderTest` for why not `FileHandle`);
/// stdout and stderr are files, polled for what has landed. `readingThroughAPipe` puts stdout on
/// a pipe instead, read without blocking, so a test can stop reading it the way a client that
/// went away does.
nonisolated final class RelaySession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let sandbox: URL
    private let outURL: URL
    private let errURL: URL
    private var inputOpen = true
    private let readsThroughAPipe: Bool
    private var outputPipe: Pipe?
    private var piped = Data()

    init(endpoint: String, readingThroughAPipe: Bool = false,
         environment overlay: [String: String] = ["ALOHAJET_AGENT_TOKEN": "test-token"]) throws {
        // A write to a relay that has already exited must fail with EPIPE, not kill the test.
        signal(SIGPIPE, SIG_IGN)
        let binary = try #require(alohajetBinary, "alohajet binary not found next to the test runner")
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-relay-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        outURL = sandbox.appendingPathComponent("stdout")
        errURL = sandbox.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["mcp", "--endpoint", endpoint]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = sandbox.path
        environment.merge(overlay) { _, override in override }
        process.environment = environment
        process.standardInput = input
        readsThroughAPipe = readingThroughAPipe
        if readingThroughAPipe {
            let pipe = Pipe()
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            outputPipe = pipe
            process.standardOutput = pipe
        } else {
            process.standardOutput = try FileHandle(forWritingTo: outURL)
        }
        process.standardError = try FileHandle(forWritingTo: errURL)
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }
    var stderr: String { String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self) }

    func send(_ frame: String) {
        let bytes = Array((frame + "\n").utf8)
        var sent = 0
        let fd = input.fileHandleForWriting.fileDescriptor
        while sent < bytes.count {
            let wrote = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if wrote < 0, errno == EINTR { continue }
            if wrote <= 0 { return }
            sent += wrote
        }
    }

    func initialize() {
        send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"relay-session","version":"1"}}}"#)
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    func callTool(_ id: Int) {
        send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"fixture_wait","arguments":{}}}"#)
    }

    func ping(_ id: Int) {
        send(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)
    }

    func cancel(_ id: Int) {
        send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id),"reason":"the client gave up"}}"#)
    }

    func closeInput() {
        guard inputOpen else { return }
        inputOpen = false
        try? input.fileHandleForWriting.close()
    }

    func deliver(_ signalNumber: Int32) { kill(process.processIdentifier, signalNumber) }

    /// Closes the read end of a piped stdout: the relay's next write fails.
    func stopReading() {
        drainPipe()
        try? outputPipe?.fileHandleForReading.close()
        outputPipe = nil
    }

    private func drainPipe() {
        guard let fd = outputPipe?.fileHandleForReading.fileDescriptor else { return }
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = read(fd, &scratch, scratch.count)
            if got <= 0 { return }
            piped.append(contentsOf: scratch[0..<got])
        }
    }

    /// Every JSON-RPC message the relay has written to stdout so far.
    var replies: [[String: Any]] {
        drainPipe()
        let output = readsThroughAPipe ? piped : (try? Data(contentsOf: outURL)) ?? Data()
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// The waits below suspend rather than sleep: a test blocked on a child process must not
    /// hold one of the few threads every async test in the run shares.
    func reply(_ id: Int, within seconds: TimeInterval) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let reply = replies.first(where: { $0["id"] as? Int == id }) { return reply }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        return nil
    }

    /// The exit status, once the relay has exited by itself within `seconds`; `nil` while it
    /// runs. Polled: `waitUntilExit` cannot give up, and a relay that never ends is the defect.
    /// A signal's death reads as the negated signal number.
    func exitStatus(within seconds: TimeInterval) async -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus
    }

    /// Ends the relay if a test left it running, and removes its files.
    func finish() {
        closeInput()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: sandbox)
    }
}
