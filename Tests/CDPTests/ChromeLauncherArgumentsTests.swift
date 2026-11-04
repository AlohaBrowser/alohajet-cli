import Testing
import Foundation
@testable import CDP

// Read off the launched process's own argv: `/usr/bin/true` takes any flags and exits, so the
// line is the one a browser would have been handed, and no browser is needed to read it.
@Suite("the command line a browser is launched with", .serialized)
struct ChromeLauncherArgumentsTests {

    private func arguments(headless: Bool, executablePath: String = "/usr/bin/true") throws -> [String] {
        let handle = try ChromeLauncher(executablePath: executablePath).launch(port: 1, headless: headless)
        defer { handle.terminate() }
        return handle.process.arguments ?? []
    }

    /// A stand-in that answers `--version` the way Chrome for Testing 153 does.
    private func withVersionedBrowser<T>(_ body: (String) throws -> T) throws -> T {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-versioned-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let browser = scratch.appendingPathComponent("browser").path
        try """
            #!/bin/sh
            [ "$1" = "--version" ] && echo "Google Chrome for Testing 153.0.8010.52 "
            exit 0

            """.write(toFile: browser, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: browser)
        return try body(browser)
    }

    #if os(macOS)
    private let platform = "Macintosh; Intel Mac OS X 10_15_7"
    #else
    private let platform = "X11; Linux x86_64"
    #endif

    @Test("a headless browser sends the User-Agent it sends from a window, which does not say HeadlessChrome")
    func headlessSendsTheWindowedUserAgent() throws {
        let line = try withVersionedBrowser { try arguments(headless: true, executablePath: $0) }
        #expect(line.contains(
            "--user-agent=Mozilla/5.0 (\(platform)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"))
        #expect(line.last == "about:blank")
    }

    @Test("a windowed browser, or one that names no version, keeps its own User-Agent")
    func ownUserAgent() throws {
        let windowed = try withVersionedBrowser { try arguments(headless: false, executablePath: $0) }
        #expect(!windowed.contains { $0.hasPrefix("--user-agent") })
        let unversioned = try arguments(headless: true)
        #expect(!unversioned.contains { $0.hasPrefix("--user-agent") })
    }

    @Test("the User-Agent a window sends is built from the major version the browser prints", arguments: [
        ("Google Chrome for Testing 153.0.8010.52 ", "153"),
        ("Google Chrome 156.0.7311.4", "156"),
        ("Chromium 120.0.6099.224 built on Ubuntu , running on Ubuntu 22.04", "120"),
    ])
    func windowedUserAgent(_ line: String, _ major: String) {
        #expect(ChromeLauncher.windowedUserAgent(versionLine: line)
            == "Mozilla/5.0 (\(platform)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36")
    }

    @Test("a line with no browser version builds none", arguments: ["", "Google Chrome", "Ubuntu 22.04", "1.2.3"])
    func noVersionNoUserAgent(_ line: String) {
        #expect(ChromeLauncher.windowedUserAgent(versionLine: line) == nil)
    }

    @Test("a browser that does not answer --version in time names no version, and is stopped")
    func versionThatHangs() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-silent-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pidFile = scratch.appendingPathComponent("pid").path
        let browser = scratch.appendingPathComponent("browser").path
        try "#!/bin/sh\necho $$ > '\(pidFile)'\nexec sleep 30\n".write(toFile: browser, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: browser)

        let started = Date()
        #expect(ChromeLauncher.versionLine(of: browser, timeout: 2) == nil)
        #expect(Date().timeIntervalSince(started) < 10)
        let written = try String(contentsOfFile: pidFile, encoding: .utf8)
        let pid = try #require(Int32(written.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(kill(pid, 0) != 0, "the silent browser \(pid) outlived its version probe")
    }

    @Test("ALOHAJET_CHROME_USER_AGENT wins, headless or windowed, and the browser is not asked its version",
          arguments: [true, false])
    func overrideWins(headless: Bool) {
        let argument = ChromeLauncher.userAgentArgument(headless: headless, override: "Custom/1") { () -> String? in
            Issue.record("the version was asked although the override names the User-Agent")
            return nil
        }
        #expect(argument == "--user-agent=Custom/1")
    }

    @Test("an empty ALOHAJET_CHROME_USER_AGENT is unset")
    func emptyOverride() {
        #expect(ChromeLauncher.userAgentArgument(headless: true, override: "") { "Google Chrome 153.0.8010.52" }
            == "--user-agent=Mozilla/5.0 (\(platform)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36")
        #expect(ChromeLauncher.userAgentArgument(headless: false, override: "") { () -> String? in
            Issue.record("a windowed browser was asked its version")
            return nil
        } == nil)
    }

    @Test("a headless browser gets the macOS app's 1440x900 window, and a screen that holds it")
    func headlessGetsADesktopWindow() throws {
        let arguments = try arguments(headless: true)
        #expect(arguments.contains("--headless=new"))
        #expect(arguments.contains("--window-size=1440,900"))
        #expect(arguments.contains("--screen-info={1440x900}"))
    }

    @Test("a windowed browser sizes its own window")
    func windowedIsLeftAlone() throws {
        let arguments = try arguments(headless: false)
        #expect(!arguments.contains { $0.hasPrefix("--headless") })
        #expect(!arguments.contains { $0.hasPrefix("--window-size") })
        #expect(!arguments.contains { $0.hasPrefix("--screen-info") })
    }

    @Test("a browser nobody is looking at keeps running at full speed, headless or windowed",
          arguments: [true, false])
    func backgroundIsNotThrottled(headless: Bool) throws {
        let arguments = try arguments(headless: headless)
        #expect(arguments.contains("--disable-background-timer-throttling"))
        #expect(arguments.contains("--disable-backgrounding-occluded-windows"))
        #expect(arguments.contains("--disable-renderer-backgrounding"))
        #expect(arguments.last == "about:blank")
    }
}
