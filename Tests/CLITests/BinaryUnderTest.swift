import Foundation
import Dispatch
import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// The CLI and the MCP server live in an executable target, which a Swift test target
// cannot import. So they are tested the way a user meets them: as a process, over argv
// and stdio. That is also the only way to assert an EXIT CODE, which is half of the CLI's
// contract and is invisible to an in-process test.

/// The `alohajet` binary this test run built, or why there is none — every case that runs
/// it FAILS on the latter (`try alohajetBinary.get()`), it does not skip.
///
/// The one beside this test bundle, in the build's own products directory: `swift test`
/// builds both there, wherever `--scratch-path` puts it. (`<package>/.build/debug` was a
/// stale binary from another build whenever this one went elsewhere.) It must not be
/// older than a Swift file under `<package>/Sources` (`#filePath`) that no build compiled
/// since: that one was not rebuilt from them (`--skip-build`). `ALOHAJET_BIN` overrides it
/// so a packaged binary can be smoke tested with the same suite; it is taken as named, but
/// must exist.
let alohajetBinary = Result {
    try resolveAlohajetBinary(
        override: ProcessInfo.processInfo.environment["ALOHAJET_BIN"],
        testImage: testImagePath(),
        sources: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package>
            .appendingPathComponent("Sources"))
}

struct BinaryUnderTestError: Error, CustomStringConvertible {
    let description: String
}

/// `testImage` is the test bundle's executable (macOS
/// `<products>/alohajetPackageTests.xctest/Contents/MacOS/…`) or the test executable
/// itself (Linux `<products>/alohajetPackageTests.xctest`); `alohajet` is its sibling.
func resolveAlohajetBinary(override: String?, testImage: String?, sources: URL) throws -> String {
    if let override, !override.isEmpty {
        guard isExecutableFile(override) else {
            throw BinaryUnderTestError(description: "ALOHAJET_BIN=\(override) is not an executable file")
        }
        return override
    }
    var bundle = URL(fileURLWithPath: testImage ?? "/").resolvingSymlinksInPath()
    while bundle.pathExtension != "xctest", bundle.pathComponents.count > 1 {
        bundle.deleteLastPathComponent()
    }
    guard bundle.pathExtension == "xctest" else {
        throw BinaryUnderTestError(description: "no .xctest bundle around the test image \(testImage ?? "nil")")
    }
    let products = bundle.deletingLastPathComponent()
    let binary = products.appendingPathComponent("alohajet").path
    guard isExecutableFile(binary) else {
        throw BinaryUnderTestError(description: "no alohajet beside the test bundle: \(binary)")
    }
    guard FileManager.default.fileExists(atPath: sources.path) else {
        throw BinaryUnderTestError(description: "no sources at \(sources.path)")
    }
    let built = try modificationDate(binary)
    let saved = try files(under: sources, withExtension: "swift")
        .map { ($0, try modificationDate($0.path)) }.filter { $0.1 > built }
    guard !saved.isEmpty else { return binary }

    // Saved after the link is not yet stale. The compiler keeps an object whose content did
    // not change, so a source saved unchanged (a checkout, a stash round trip) is recompiled
    // and NOT relinked: newer than the binary, yet in it, and no build ever relinks it
    // (measured, native and swiftbuild alike). That compile does rewrite the source's
    // `<name>.d`, two levels above the products directory either way: native
    // `<scratch>/<triple>/debug/<Target>.build/`, swiftbuild `<scratch>/out/Intermediates.noindex/…`.
    var compiled: [String: Date] = [:]
    for list in files(under: products.deletingLastPathComponent().deletingLastPathComponent(), withExtension: "d") {
        let name = list.deletingPathExtension().lastPathComponent
        compiled[name] = max(compiled[name] ?? .distantPast, try modificationDate(list.path))
    }
    for (file, savedAt) in saved where (compiled[file.deletingPathExtension().lastPathComponent] ?? .distantPast) < savedAt {
        throw BinaryUnderTestError(description: """
            \(binary) is older than \(file.path), and no build compiled it since \
            (swift test --skip-build?). Build it, or name a binary with ALOHAJET_BIN.
            """)
    }
    return binary
}

private func files(under directory: URL, withExtension pathExtension: String) -> [URL] {
    let all = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects ?? []
    return all.compactMap { $0 as? URL }.filter { $0.pathExtension == pathExtension }
}

private func modificationDate(_ path: String) throws -> Date {
    try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date ?? .distantPast
}

/// The image this code is linked into: the test bundle's executable, not the `xctest` /
/// `swiftpm-testing-helper` host that `CommandLine.arguments[0]` names on macOS.
func testImagePath() -> String? {
    #if canImport(Darwin)
    var info = Dl_info()
    guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return nil }
    return String(cString: name)
    #else
    return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
    #endif
}

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
/// `HOME` / `CFFIXED_USER_HOME` too: the binary is no test process (``HostAppIdentity``
/// cannot tell it apart from the user's `alohajet`), so with the real home it kept its URL
/// cache and cookies in the user's `~/Library/Caches/alohajet` and `HTTPStorages/alohajet`
/// (measured), and would read the user's `~/.alohajet` and `Application Support/Aloha`.
///
/// FILES, NOT PIPES, for all three streams. Pipes cost two things this suite cannot
/// pay: a reader per stream (a child that fills one 64K pipe buffer while the test
/// blocks on the other deadlocks), and `FileHandle.write` — which on Linux is a `try!`
/// inside corelibs-Foundation that turns an ordinary `EINTR` into a fatal error and
/// took the whole test process down on the first Linux run. A file has no buffer limit
/// and needs no writer.
@discardableResult
func runCLI(
    _ arguments: [String], stdin: String? = nil, terminal: String? = nil,
    environment overlay: [String: String] = [:], timeout: TimeInterval = 30
) throws -> RunOutput {
    let binary = try alohajetBinary.get()
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
    environment["HOME"] = sandbox.path
    environment["CFFIXED_USER_HOME"] = sandbox.path
    // The overlay LAST, and it is how the agent cases pin `ALOHAJET_AGENT_TOKEN`: the
    // developer running this suite has a real one on disk, and a test must neither
    // depend on it nor hand it to a stub.
    environment.merge(overlay) { _, override in override }
    process.environment = environment
    let pty = try terminal.map { _ in try openTerminal() }
    defer { if let pty { close(pty.slave); close(pty.master) } }
    if let pty, let terminal {
        _ = terminal.withCString { write(pty.master, $0, strlen($0)) }
    }
    process.standardInput = try pty.map { FileHandle(fileDescriptor: $0.slave) } ?? FileHandle(forReadingFrom: inURL)
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

#if canImport(Darwin)
private func openTerminal() throws -> (master: Int32, slave: Int32) {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    try #require(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0)
    let slave = open(try #require(ptsname(master)), O_RDWR | O_NOCTTY)
    try #require(slave >= 0)
    return (master, slave)
}
#else
private struct NoTerminal: Error {}

private func openTerminal() throws -> (master: Int32, slave: Int32) {
    throw NoTerminal()
}
#endif
