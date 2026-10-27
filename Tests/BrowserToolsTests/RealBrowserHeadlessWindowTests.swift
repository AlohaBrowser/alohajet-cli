import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// Chrome's headless default is an 800x600 screen and a 780-wide viewport, which sites answer with
// their narrow layout: ru.wikipedia folds its search box into a link and hides both inputs, so an
// agent asked to search there could not. Measured from the page, which is what a site reads.

private nonisolated let windowBrowserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let windowBrowserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

@Suite("a headless browser's window, real browser", .serialized,
       .enabled(if: windowBrowserIsAvailable || windowBrowserIsRequired))
struct RealBrowserHeadlessWindowTests {

    @Test("a page in a headless browser sees a 1440-wide viewport on a 1440x900 screen")
    func pageSeesADesktopViewport() async throws {
        try #require(windowBrowserIsAvailable,
                     "no browser at \(ChromeLauncher().executablePath), and ALOHAJET_REQUIRE_BROWSER is set")
        let measured = try await withHeadlessBrowser { session in
            let client = session.client
            let target = try await client.openTab(url: "about:blank")
            let page = try await client.attachToTarget(targetId: target)
            let result = try await client.send(
                method: "Runtime.evaluate",
                params: [
                    "expression": .string("[innerWidth, innerHeight, screen.width, screen.height]"),
                    "returnByValue": .bool(true),
                ],
                sessionId: page)
            return (result["result"]?["value"]?.arrayValue ?? []).compactMap(\.intValue)
        }
        try #require(measured.count == 4, "the page reported \(measured)")
        let (innerWidth, innerHeight, screenWidth, screenHeight) = (measured[0], measured[1], measured[2], measured[3])
        #expect(innerWidth == 1440)
        #expect(innerHeight > 600 && innerHeight <= 900, "innerHeight \(innerHeight)")
        #expect(screenWidth == 1440 && screenHeight == 900, "screen \(screenWidth)x\(screenHeight)")
    }
}
