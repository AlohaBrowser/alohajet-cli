#if os(macOS) || os(Linux)
import Testing
import Foundation
@testable import CDP

// Chrome binds its process-singleton socket in a `<product>.XXXXXX` directory under its TMPDIR,
// and points the profile's `SingletonSocket` link at it. It removes that directory on an orderly
// exit only, so a browser stopped by SIGTERM or SIGKILL left one behind per launch. Laid out
// here as Chrome lays it out, measured off Chrome 156 on Linux.
@Suite("the singleton socket directory a stopped browser leaves", .serialized)
final class SingletonSocketDirectoryTests {

    private let scratch: URL
    private let manager = FileManager.default

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-singleton-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    /// `profile`'s three singleton links, the way a browser with pid `pid` writes them, and the
    /// directory its socket link points into, holding the socket and the cookie.
    @discardableResult
    private func singleton(
        profile: URL, pid: Int32, directoryName: String = "com.google.Chrome.AbC123",
        socketName: String = "SingletonSocket"
    ) throws -> URL {
        let directory = scratch.appendingPathComponent(directoryName, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: directory.appendingPathComponent("SingletonSocket"))
        try manager.createSymbolicLink(
            atPath: directory.appendingPathComponent("SingletonCookie").path, withDestinationPath: "4242")
        try manager.createDirectory(at: profile, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            atPath: profile.appendingPathComponent("SingletonLock").path, withDestinationPath: "host-name-\(pid)")
        try manager.createSymbolicLink(
            atPath: profile.appendingPathComponent("SingletonSocket").path,
            withDestinationPath: directory.appendingPathComponent(socketName).path)
        try manager.createSymbolicLink(
            atPath: profile.appendingPathComponent("SingletonCookie").path, withDestinationPath: "4242")
        return directory
    }

    private func exists(_ url: URL) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)) != nil
    }

    /// A browser that has already exited, so terminate() has nothing left to signal.
    private func exitedLaunch(userDataDir: URL? = nil) throws -> ChromeLauncher.Handle {
        let handle = try ChromeLauncher(executablePath: "/usr/bin/true").launch(port: 1, userDataDir: userDataDir)
        let deadline = Date().addingTimeInterval(5)
        while handle.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        try #require(!handle.process.isRunning)
        return handle
    }

    @Test("terminate removes the directory a throwaway profile's socket link points into, and nothing beside it")
    func terminateRemovesTheDirectory() throws {
        let handle = try exitedLaunch()
        let directory = try singleton(profile: handle.userDataDir, pid: handle.process.processIdentifier)
        let sentinel = scratch.appendingPathComponent("sentinel")
        try Data("kept".utf8).write(to: sentinel)

        handle.terminate()

        #expect(!exists(directory))
        #expect(!exists(handle.userDataDir))
        #expect(exists(sentinel))
        handle.terminate()
    }

    @Test("a caller's own profile keeps its links; only the directory in the browser's temp goes")
    func providedProfileIsOnlyRead() throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        try manager.createDirectory(at: profile, withIntermediateDirectories: true)
        let handle = try exitedLaunch(userDataDir: profile)
        let directory = try singleton(profile: profile, pid: handle.process.processIdentifier)

        handle.terminate()

        #expect(!exists(directory))
        for link in ["SingletonLock", "SingletonSocket", "SingletonCookie"] {
            #expect(exists(profile.appendingPathComponent(link)), "\(link) was removed from the caller's profile")
        }
    }

    @Test("the directory of a lock some other browser holds is left alone")
    func anotherBrowsersLockIsLeftAlone() throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        let directory = try singleton(profile: profile, pid: 4242)
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 424)
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 14242)
        #expect(exists(directory))
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 4242)
        #expect(!exists(directory))
    }

    @Test("a directory that is not Chrome's <product>.XXXXXX is left alone", arguments: [
        "alohajet-1000", "com.google.Chrome.chrome_chrome_url_fetcher_.9yuo3U", "com.google.Chrome.AbC12",
        "Chrome.AbC123", "com.google..AbC123",
    ])
    func foreignDirectoryNamesAreLeftAlone(_ name: String) throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        let directory = try singleton(profile: profile, pid: 4242, directoryName: name)
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 4242)
        #expect(exists(directory))
    }

    @Test("Chromium's and a leading-dot product name are Chrome's", arguments: [
        "org.chromium.Chromium.Zz09aB", ".com.google.Chrome.AbC123",
    ])
    func otherProductNamesAreRemoved(_ name: String) throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        let directory = try singleton(profile: profile, pid: 4242, directoryName: name)
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 4242)
        #expect(!exists(directory))
    }

    @Test("a directory holding anything but the socket and its cookie is left whole")
    func anythingElseInsideKeepsTheDirectory() throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        let directory = try singleton(profile: profile, pid: 4242)
        try Data("theirs".utf8).write(to: directory.appendingPathComponent("notes"))
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 4242)
        for entry in ["SingletonSocket", "SingletonCookie", "notes"] {
            #expect(exists(directory.appendingPathComponent(entry)), "\(entry) was removed")
        }
    }

    @Test("a socket link that does not end in SingletonSocket is not followed")
    func aLinkToSomethingElseIsNotFollowed() throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        let directory = try singleton(profile: profile, pid: 4242, socketName: "SingletonCookie")
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 4242)
        #expect(exists(directory))
    }

    @Test("a link to a directory, even one that looks like Chrome's, is not removed through")
    func aSymlinkedDirectoryIsLeftAlone() throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        let real = try singleton(profile: profile, pid: 4242, directoryName: "real")
        let link = scratch.appendingPathComponent("com.google.Chrome.LnK123")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        try manager.removeItem(at: profile.appendingPathComponent("SingletonSocket"))
        try manager.createSymbolicLink(
            atPath: profile.appendingPathComponent("SingletonSocket").path,
            withDestinationPath: link.appendingPathComponent("SingletonSocket").path)
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 4242)
        #expect(exists(link))
        #expect(exists(real.appendingPathComponent("SingletonSocket")))
    }

    @Test("a profile with no singleton links, or none left, is a no-op")
    func nothingToRemove() throws {
        let profile = scratch.appendingPathComponent("profile", isDirectory: true)
        try manager.createDirectory(at: profile, withIntermediateDirectories: true)
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: profile, lockedBy: 4242)
        ChromeLauncher.removeSingletonSocketDirectory(ofProfile: scratch.appendingPathComponent("absent"), lockedBy: 4242)
        #expect(exists(profile))
    }
}
#endif
