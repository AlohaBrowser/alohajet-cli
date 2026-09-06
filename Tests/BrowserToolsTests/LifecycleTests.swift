import Foundation
import Testing
import CDP
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

@MainActor private func makeProfile(owner: String?) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("alohajet-cdp-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // A file the reaper must take with it, so "the directory is gone" means the whole
    // profile is gone and not just the marker.
    try? Data("profile".utf8).write(to: dir.appendingPathComponent("Preferences"))
    if let owner {
        try? Data(owner.utf8).write(
            to: dir.appendingPathComponent(ChromeLauncher.ownerPidFileName))
    }
    return dir
}

@Test @MainActor func reapsAProfileWhoseOwningRunIsGone() {
    let dir = makeProfile(owner: "\(deadPid())\n")
    ChromeLauncher.reapStaleProfiles()
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test @MainActor func keepsAProfileWhoseOwningRunIsStillAlive() {
    // Our own pid: a session in progress, which is what a concurrent `alohajet` is.
    let dir = makeProfile(owner: "\(getpid())")
    defer { try? FileManager.default.removeItem(at: dir) }
    ChromeLauncher.reapStaleProfiles()
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

@Test @MainActor func keepsAProfileThatClaimsNoOwner() {
    // Three things wear this shape: a directory from an older build, one a concurrent run
    // created microseconds ago and has not stamped yet, and one deliberately disowned so
    // its browser can outlive the run. None of them is ours to delete.
    let dir = makeProfile(owner: nil)
    defer { try? FileManager.default.removeItem(at: dir) }
    ChromeLauncher.reapStaleProfiles()
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

@Test @MainActor func keepsAProfileWhoseOwnerFileIsNotAPid() {
    let dir = makeProfile(owner: "not-a-pid")
    defer { try? FileManager.default.removeItem(at: dir) }
    ChromeLauncher.reapStaleProfiles()
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

// The stderr log is a sibling of the profile with an unrelated UUID, so the pid-proof
// above cannot reach it. Age stands in for ownership; both directions are proven here
// because "delete a file in /tmp on a clock" is the other kind of code that has to be
// wrong exactly once.

@MainActor private func makeStderrLog(ageInSeconds: TimeInterval) -> URL {
    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("alohajet-chrome-stderr-\(UUID().uuidString).log")
    try? Data("chrome said things".utf8).write(to: log)
    try? FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-ageInSeconds)], ofItemAtPath: log.path)
    return log
}

@Test @MainActor func reapsAStderrLogNobodyHasWrittenToInADay() {
    let log = makeStderrLog(ageInSeconds: 2 * 86_400)
    ChromeLauncher.reapStaleProfiles()
    #expect(!FileManager.default.fileExists(atPath: log.path))
}

@Test @MainActor func keepsAStderrLogARunningBrowserMayStillBeWriting() {
    let log = makeStderrLog(ageInSeconds: 30)
    defer { try? FileManager.default.removeItem(at: log) }
    ChromeLauncher.reapStaleProfiles()
    #expect(FileManager.default.fileExists(atPath: log.path))
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
