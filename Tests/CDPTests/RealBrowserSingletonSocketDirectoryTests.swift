#if os(Linux)
import Testing
import Foundation
@testable import CDP

private nonisolated let browserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let browserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

// SIGTERM is what terminate() sends first, and a Chrome that exits on it leaves its singleton
// socket directory and the profile's links to it behind (measured, Chrome 156).
@Suite("a terminated browser's singleton socket directory, real browser", .serialized,
       .enabled(if: browserIsAvailable || browserIsRequired))
struct RealBrowserSingletonSocketDirectoryTests {

    @Test("terminate leaves no singleton socket directory behind", arguments: [false, true])
    func terminateRemovesTheDirectory(callerProfile: Bool) async throws {
        try #require(browserIsAvailable,
                     "no browser at \(ChromeLauncher().executablePath), and ALOHAJET_REQUIRE_BROWSER is set")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-real-singleton-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let launcher = ChromeLauncher()
        let port = try freeLoopbackPort()
        let handle = try launcher.launch(port: port, userDataDir: callerProfile ? scratch : nil)
        defer { handle.terminate() }
        _ = try await launcher.discoverWebSocketURL(port: port, timeout: 30, handle: handle)
        let socket = try FileManager.default.destinationOfSymbolicLink(
            atPath: handle.userDataDir.appendingPathComponent("SingletonSocket").path)
        let directory = (socket as NSString).deletingLastPathComponent
        try #require(FileManager.default.fileExists(atPath: directory), "control: no \(directory) while running")

        handle.terminate()

        #expect(!FileManager.default.fileExists(atPath: directory), "\(directory) outlived its browser")
        #expect(FileManager.default.fileExists(atPath: scratch.path))
    }
}
#endif
