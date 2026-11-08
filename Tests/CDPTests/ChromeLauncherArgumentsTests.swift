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
