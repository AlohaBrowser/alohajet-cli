import Foundation
import Testing
@testable import CDP
import ToolABI
@testable import BrowserTools

// The two things that must not go wrong when a run ends badly: a browser we launched must
// not survive us, and the reaper that catches the ones that did must never delete somebody
// else's profile. The first needs a live Chromium and a signal, so it is proven by hand
// (see the run in this change's report); the second is pure file-system logic and is
// proven here, because "delete a directory in /tmp" is the kind of code that has to be
// wrong exactly once.

/// A pid that is certainly dead: a real child, run to completion and reaped. Not a made-up
/// number — that could name a live process and the test would then assert the opposite of
/// what it means to.
private func deadPid() -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

// Each call gets an owned namespace, including logs. Never sweep the process's
// global temporary directory, even when the suite is run without a TMPDIR override.
@MainActor private func makeReaperRoot() throws -> URL {
    let root = temporaryDirectory.appendingPathComponent("reaper-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor private func makeProfile(in root: URL, owner: String?) throws -> URL {
    let dir = root.appendingPathComponent("alohajet-cdp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("profile".utf8).write(to: dir.appendingPathComponent("Preferences"))
    if let owner {
        try Data(owner.utf8).write(to: dir.appendingPathComponent(ChromeLauncher.ownerPidFileName))
    }
    return dir
}

@Test @MainActor func reapsAProfileWhoseOwningRunIsGone() throws {
    let root = try makeReaperRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try makeProfile(in: root, owner: "\(deadPid())\n")
    ChromeLauncher.reapStaleProfiles(in: root)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test @MainActor func keepsAProfileWhoseOwningRunIsStillAlive() throws {
    let root = try makeReaperRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Our own pid: a session in progress, which is what a concurrent `alohajet` is.
    let dir = try makeProfile(in: root, owner: "\(getpid())")
    defer { try? FileManager.default.removeItem(at: dir) }
    ChromeLauncher.reapStaleProfiles(in: root)
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

@Test @MainActor func keepsAProfileThatClaimsNoOwner() throws {
    let root = try makeReaperRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Three things wear this shape: a directory from an older build, one a concurrent run
    // created microseconds ago and has not stamped yet, and one deliberately disowned so
    // its browser can outlive the run. None of them is ours to delete.
    let dir = try makeProfile(in: root, owner: nil)
    defer { try? FileManager.default.removeItem(at: dir) }
    ChromeLauncher.reapStaleProfiles(in: root)
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

@Test @MainActor func keepsAProfileWhoseOwnerFileIsNotAPid() throws {
    let root = try makeReaperRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try makeProfile(in: root, owner: "not-a-pid")
    defer { try? FileManager.default.removeItem(at: dir) }
    ChromeLauncher.reapStaleProfiles(in: root)
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

// The stderr log is a sibling of the profile with an unrelated UUID, so the pid-proof
// above cannot reach it. Age stands in for ownership; both directions are proven here
// because "delete a file in /tmp on a clock" is the other kind of code that has to be
// wrong exactly once.

@MainActor private func makeStderrLog(in root: URL, ageInSeconds: TimeInterval) throws -> URL {
    let log = root
        .appendingPathComponent("alohajet-chrome-stderr-\(UUID().uuidString).log")
    try Data("chrome said things".utf8).write(to: log)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-ageInSeconds)], ofItemAtPath: log.path)
    return log
}

@Test @MainActor func reapsAStderrLogNobodyHasWrittenToInADay() throws {
    let root = try makeReaperRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try makeStderrLog(in: root, ageInSeconds: 2 * 86_400)
    ChromeLauncher.reapStaleProfiles(in: root)
    #expect(!FileManager.default.fileExists(atPath: log.path))
}

@Test @MainActor func keepsAStderrLogARunningBrowserMayStillBeWriting() throws {
    let root = try makeReaperRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try makeStderrLog(in: root, ageInSeconds: 30)
    defer { try? FileManager.default.removeItem(at: log) }
    ChromeLauncher.reapStaleProfiles(in: root)
    #expect(FileManager.default.fileExists(atPath: log.path))
}

// Both roots belong to this test. A dead profile and old log in the sibling
// prove that the selected root is scanned and its sibling is left untouched.
@Test @MainActor func reaperNeverCrossesItsOwnedRoot() throws {
    let parent = try makeReaperRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let first = parent.appendingPathComponent("first")
    let sibling = parent.appendingPathComponent("sibling")
    for root in [first, sibling] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: root.appendingPathComponent("sentinel"))
    }
    let owner = "\(deadPid())"
    let removed = try makeProfile(in: first, owner: owner)
    let retained = try makeProfile(in: sibling, owner: owner)
    let removedLog = try makeStderrLog(in: first, ageInSeconds: 2 * 86_400)
    let retainedLog = try makeStderrLog(in: sibling, ageInSeconds: 2 * 86_400)
    ChromeLauncher.reapStaleProfiles(in: first)
    #expect(!FileManager.default.fileExists(atPath: removed.path))
    #expect(!FileManager.default.fileExists(atPath: removedLog.path))
    #expect(FileManager.default.fileExists(atPath: retained.path))
    #expect(FileManager.default.fileExists(atPath: retainedLog.path))
    for root in [first, sibling] {
        #expect(try Data(contentsOf: root.appendingPathComponent("sentinel")) == Data("sentinel".utf8))
    }
    ChromeLauncher.reapStaleProfiles(in: sibling)
    #expect(!FileManager.default.fileExists(atPath: retained.path))
    #expect(!FileManager.default.fileExists(atPath: retainedLog.path))
}

// MARK: - Ports

// `alohajet --cdp 99999 tabs` trapped with "Not enough bits to represent the passed value"
// and exit 133. A port arrives from argv; argv must not be able to kill the process.

@Test func aPortTooWideForTCPIsAnErrorAndNotATrap() async {
    await #expect(throws: (any Error).self) {
        _ = try await CDPClient.discoverWebSocketURL(host: "127.0.0.1", port: 99_999)
    }
}

@Test func theLauncherRefusesAPortItCouldNeverBind() {
    #expect(throws: (any Error).self) {
        _ = try ChromeLauncher(executablePath: "/usr/bin/true").launch(port: 99_999)
    }
}

// MARK: - page_type's cap

@Test func typingIsBoundedWellBelowWhatWouldWedgeTheSession() {
    // Two CDP round-trips per character: the 2,000,000-character call that had to be
    // killed after 120s is four million of them. The bound is what makes that arithmetic
    // impossible, so it is the thing worth pinning.
    #expect(PageTypeExecutorTool.maxTextLength <= 100_000)
    let refusal = PageTypeExecutorTool.refuseTooLong("abc123", 2_000_000)
    #expect(refusal.isError == true)
    #expect(refusal.output.contains("2000000"))
    #expect(refusal.output.contains("abc123"))
}
