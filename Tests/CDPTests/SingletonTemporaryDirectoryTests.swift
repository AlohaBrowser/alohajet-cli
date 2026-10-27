#if os(Linux)
import Testing
import Foundation
import Glibc
@testable import CDP

// Chromium on Linux binds its process-singleton socket at
// `$TMPDIR/<product>.XXXXXX/SingletonSocket` and dies with "Socket path too long" when that
// overflows `sun_path`. The browser a launch starts is given a short private TMPDIR instead
// whenever the inherited one would overflow, and only then.
@Suite("the TMPDIR a launched browser gets", .serialized)
struct SingletonTemporaryDirectoryTests {

    private func path(bytes: Int) -> String {
        "/" + String(repeating: "t", count: bytes - 1)
    }

    @Test("the bound is what sun_path leaves after Chromium's socket template")
    func boundIsSunPathMinusTheTemplate() {
        // 108 bytes of sun_path with its NUL, minus "/org.chromium.Chromium.XXXXXX/SingletonSocket".
        #expect(ChromeLauncher.longestSingletonTemporaryDirectory == 62)
    }

    @Test("a TMPDIR at the bound is left alone, one byte past it is not")
    func boundIsInclusive() {
        #expect(!ChromeLauncher.singletonSocketOverflows(temporaryDirectory: path(bytes: 62)))
        #expect(ChromeLauncher.singletonSocketOverflows(temporaryDirectory: path(bytes: 63)))
        #expect(!ChromeLauncher.singletonSocketOverflows(temporaryDirectory: "/tmp"))
        #expect(!ChromeLauncher.singletonSocketOverflows(temporaryDirectory: ""))
    }

    @Test("trailing slashes do not count: Chromium strips them before appending")
    func trailingSlashesAreNotCounted() {
        #expect(!ChromeLauncher.singletonSocketOverflows(temporaryDirectory: path(bytes: 62) + "//"))
        #expect(!ChromeLauncher.singletonSocketOverflows(temporaryDirectory: "/"))
    }

    @Test("the bound is in bytes, not characters")
    func boundIsInBytes() {
        let twoByte = "/" + String(repeating: "é", count: 31)
        #expect(twoByte.count == 32)
        #expect(ChromeLauncher.singletonSocketOverflows(temporaryDirectory: twoByte))
    }

    @Test("an inherited TMPDIR that fits, or none at all, is inherited unchanged")
    func shortTemporaryDirectoryIsInherited() throws {
        let fallback = "/nonexistent/never-created"
        try #expect(ChromeLauncher.browserEnvironment(
            inheriting: ["TMPDIR": "/tmp", "HOME": "/home/u"], fallback: fallback) == nil)
        try #expect(ChromeLauncher.browserEnvironment(
            inheriting: ["HOME": "/home/u"], fallback: fallback) == nil)
        #expect(!FileManager.default.fileExists(atPath: fallback))
    }

    @Test("a TMPDIR that would overflow is replaced by the private one, and nothing else changes")
    func longTemporaryDirectoryIsReplaced() throws {
        try withScratch { scratch in
            let fallback = scratch.appendingPathComponent("short").path
            let environment = try ChromeLauncher.browserEnvironment(
                inheriting: ["TMPDIR": path(bytes: 80), "HOME": "/home/u"], fallback: fallback)
            #expect(environment == ["TMPDIR": fallback, "HOME": "/home/u"])
            #expect(mode(of: fallback) == 0o700)
        }
    }

    @Test("the private directory is created 0700, and reused when it already is one")
    func privateDirectoryIsCreatedAndReused() throws {
        try withScratch { scratch in
            let directory = scratch.appendingPathComponent("short").path
            try #expect(ChromeLauncher.privateDirectory(at: directory) == directory)
            #expect(mode(of: directory) == 0o700)
            try #expect(ChromeLauncher.privateDirectory(at: directory) == directory)
        }
    }

    @Test("anything but a directory only this user can enter is refused")
    func foreignDirectoriesAreRefused() throws {
        try withScratch { scratch in
            let open = scratch.appendingPathComponent("open").path
            #expect(mkdir(open, 0o700) == 0 && chmod(open, 0o755) == 0)
            #expect(throws: CDPError.self) { try ChromeLauncher.privateDirectory(at: open) }

            let target = scratch.appendingPathComponent("target").path
            let link = scratch.appendingPathComponent("link").path
            #expect(mkdir(target, 0o700) == 0 && symlink(target, link) == 0)
            #expect(throws: CDPError.self) { try ChromeLauncher.privateDirectory(at: link) }

            let file = scratch.appendingPathComponent("file").path
            #expect(FileManager.default.createFile(
                atPath: file, contents: nil, attributes: [.posixPermissions: 0o700]))
            #expect(throws: CDPError.self) { try ChromeLauncher.privateDirectory(at: file) }
        }
    }

    private func withScratch(_ body: (URL) throws -> Void) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-singleton-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try body(scratch)
    }

    private func mode(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }
}
#endif
