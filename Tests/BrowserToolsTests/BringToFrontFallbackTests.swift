import Foundation
import Testing
import CDP
@testable import BrowserTools

// `Page.bringToFront` is the ONE CDP method this package sends that the Aloha browser's
// own CDP server does not implement (its `PageDomain` answers `-32601 Method not found`).
// We send it in exactly two places, both as a RECOVERY: a headless Chromium's background
// tab has no compositor, so `fromSurface` capture hangs past 20s, and bringToFront brings
// it to ~90ms.
//
// So the recovery must be best-effort — and best-effort ON THE RESPONSE. Nothing here
// asks who the browser is, because nothing in production may: `--cdp` points at whatever
// endpoint the user names, `/json/version` strings belong to the browser and change, and
// the workaround is for a *Chromium behaviour*, not for a browser's identity. An endpoint
// that answers "method not found" is telling us the recovery is unavailable there; the
// capture still has to come back.
//
// These two cases fail the moment someone drops a `try?` or makes the call mandatory.

@Suite("Page.bringToFront is optional, on the response")
struct BringToFrontFallbackTests {

    @MainActor
    private func fixtureRefusingBringToFront() async throws -> PageToolsCDPFixture {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.methodsNotImplemented = ["Page.bringToFront"]
        return fixture
    }

    @Test("a capture still yields bytes when the endpoint has no bringToFront")
    @MainActor
    func captureSurvivesMethodNotFound() async throws {
        let fixture = try await fixtureRefusingBringToFront()
        // The first capture comes back with empty `data` — the background-tab case the
        // recovery exists for — so the retry behind bringToFront is the one that must run.
        fixture.cdp.screenshotEmptyRemaining = 1
        fixture.cdp.screenshotData = "QUJD"

        let handle = try #require(
            fixture.tabsService.window!.tabs.tab(fixture.tabId) as? CDPTabHandle,
            "the fixture tab is not CDP-backed")
        let metadata = try await handle.browserTab.getViewportBase64WithMetadata("png", 1)

        let captured = try #require(metadata, "the capture returned nothing")
        #expect(captured.base64 == "data:image/png;base64,QUJD")
        // Not merely "it did not throw": the refused call was actually attempted, so the
        // test would still fail if someone silently stopped sending it on this path.
        #expect(fixture.cdp.received("Page.bringToFront"))
    }

    @Test("the refusal is the CDP error a real endpoint sends, not a transport failure")
    @MainActor
    func refusalIsARemoteMethodNotFound() async throws {
        let fixture = try await fixtureRefusingBringToFront()
        await #expect(throws: CDPError.self) {
            _ = try await fixture.client.send(method: "Page.bringToFront", params: [:])
        }
    }
}
