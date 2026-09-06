import Foundation
import Dispatch
import Testing

// The CLI and the MCP server live in an executable target, which a Swift test target
// cannot import. So they are tested the way a user meets them: as a process, over argv
// and stdio. That is also the only way to assert an EXIT CODE, which is half of the CLI's
// contract and is invisible to an in-process test.

/// The `alohajet` binary this test run built.
///
/// Found from `#filePath` — `<package>/Tests/CLITests/BinaryUnderTest.swift` — because
/// `CommandLine.arguments[0]` inside a test bundle is the `xctest` host, not anything
/// next to the product. `ALOHAJET_BIN` overrides it so a packaged binary can be smoke
/// tested with the same suite. `nil` is the signal to skip: the binary is a product of
/// the same build, so its absence means the harness changed shape, not that the CLI broke.
let alohajetBinary: String? = {
    if let override = ProcessInfo.processInfo.environment["ALOHAJET_BIN"], !override.isEmpty {
        return isExecutableFile(override) ? override : nil
    }
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/CLITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <package>
    for configuration in ["debug", "release"] {
        let candidate = packageRoot
            .appendingPathComponent(".build/\(configuration)/alohajet").path
        if isExecutableFile(candidate) { return candidate }
    }
    return nil
}()

private func isExecutableFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
        && FileManager.default.isExecutableFile(atPath: path)
}

struct RunOutput {
    var status: Int32
    var stdout: String
    var stderr: String
    var combined: String { stdout + stderr }
}

/// Runs the CLI with `arguments` and returns its exit status and streams.
///
/// `TMPDIR` is redirected at a fresh directory for every call. The default lane records
/// the browser it launched under `<tmp>/alohajet-<uid>/browser.json` and REUSES it, so a
/// test inheriting the developer's real TMPDIR would attach to whatever browser that
/// developer happens to have open — and, worse, could leave one behind. With a private
/// TMPDIR every case below is one that fails before any browser is reached.
///
/// FILES, NOT PIPES, for all three streams. Pipes cost two things this suite cannot
/// pay: a reader per stream (a child that fills one 64K pipe buffer while the test
/// blocks on the other deadlocks), and `FileHandle.write` — which on Linux is a `try!`
/// inside corelibs-Foundation that turns an ordinary `EINTR` into a fatal error and
/// took the whole test process down on the first Linux run. A file has no buffer limit
/// and needs no writer.
@discardableResult
func runCLI(_ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 30) throws -> RunOutput {
    let binary = try #require(alohajetBinary, "alohajet binary not found next to the test runner")
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("alohajet-cli-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let inURL = sandbox.appendingPathComponent("stdin")
    let outURL = sandbox.appendingPathComponent("stdout")
    let errURL = sandbox.appendingPathComponent("stderr")
    try Data((stdin ?? "").utf8).write(to: inURL)
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["TMPDIR"] = sandbox.path
    process.environment = environment
    process.standardInput = try FileHandle(forReadingFrom: inURL)
    process.standardOutput = try FileHandle(forWritingTo: outURL)
    process.standardError = try FileHandle(forWritingTo: errURL)
    try process.run()

    // A watchdog rather than a poll loop: `waitUntilExit` blocks this thread, and a CLI
    // that wedges must fail the test rather than hang the run.
    let watchdog = DispatchWorkItem { [weak process] in
        guard let process, process.isRunning else { return }
        process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    process.waitUntilExit()
    let timedOut = !watchdog.isCancelled && process.terminationReason == .uncaughtSignal
    watchdog.cancel()
    if timedOut {
        Issue.record("alohajet \(arguments.joined(separator: " ")) did not exit within \(timeout)s")
    }

    return RunOutput(
        status: process.terminationStatus,
        stdout: String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self),
        stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self))
}
