import Foundation
import Testing
import ToolABI
import CDP
@testable import BrowserTools

// A browser's own screens are not tabs the agent may drive.
//
// hn-swift-r13/r14 (2026-09-23): the model listed the browser's tabs, took "Aloha Passcode"
// (`aloha://passcode_lock_screen`, seeded from `Target.getTargets` as a "website" tab) into use,
// navigated it to Hacker News, and the "98 comments" link never navigated — three clicks in a
// row, in two runs — while the same click in an agent-opened tab navigates every time.
// `seedFromBrowser` now keeps only http(s) page targets and the initial `about:blank`, the same
// rule the click-spawned adoption applies.

@Suite("internal tabs are not seeded") @MainActor struct InternalTabsNotSeededTests {

    @Test func websitesAndTheBlankTabAreSeededInternalScreensAreNot() async throws {
        let cdp = MockCDP()
        cdp.addTarget(id: "t-passcode", url: "aloha://passcode_lock_screen", title: "Aloha Passcode")
        cdp.addTarget(id: "t-settings", url: "chrome://settings/", title: "Settings")
        cdp.addTarget(id: "t-blank", url: "about:blank")
        cdp.addTarget(id: "t-site", url: "https://news.ycombinator.com/", title: "Hacker News")
        let channel = cdp.channel()
        let client = CDPClient(channel: channel)
        try await client.connect()

        let service = await makeCDPBrowserTabsService(client: client)
        let tabs = try #require(service.window).tabs

        #expect(tabs.tab("t-site") != nil)
        #expect(tabs.tab("t-blank") != nil)
        #expect(tabs.tab("t-passcode") == nil)
        #expect(tabs.tab("t-settings") == nil)
        #expect(tabs.orderedTabs.count == 2)
    }
}
