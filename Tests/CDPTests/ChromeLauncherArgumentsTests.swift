import Testing
import Foundation
@testable import CDP

// Read off the launched process's own argv: `/usr/bin/true` takes any flags and exits, so the
// line is the one a browser would have been handed, and no browser is needed to read it.
@Suite("the command line a browser is launched with", .serialized)
struct ChromeLauncherArgumentsTests {

    private func arguments(headless: Bool) throws -> [String] {
        let handle = try ChromeLauncher(executablePath: "/usr/bin/true").launch(port: 1, headless: headless)
        defer { handle.terminate() }
        return handle.process.arguments ?? []
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
}
