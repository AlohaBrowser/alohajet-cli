import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// `CDPTabHandle.pageIdentity()` answers "which page is this tab showing?" for a caller that compares
// two readings to tell whether something brought up a new page. Each test is named for the wrong
// answer it catches: a new page missed, or no new page counted as one.
//
// The first three drive a real headless Chrome. Like the other real-browser suites they skip when no
// browser is installed, unless `ALOHAJET_REQUIRE_BROWSER=1` makes a missing browser a failure.

// `nonisolated`: the trait is evaluated outside the main actor, and this target builds with
// `defaultIsolation(MainActor.self)`.
private nonisolated let browserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let browserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

/// The local page server answers every path with this page, so `/next` after the route change is
/// still it.
private let identityFixtureHTML = """
<!doctype html>
<html><head><title>Identity Fixture</title></head>
<body>
  <a id="route" href="/next" onclick="history.pushState({}, '', '/next'); return false">Next</a>
  <a id="jump" href="#section">Jump</a>
  <h2 id="section">Section</h2>
</body></html>
"""

private let noBrowser =
    "no browser at \(ChromeLauncher().executablePath) — ALOHAJET_REQUIRE_BROWSER is set, so this is a failure, not a skip"

@Suite("page identity", .serialized)
struct PageIdentityTests {

    /// A single-page app changes pages with `history.pushState`: a new address in the same document.
    /// Taken from the tab's cached url, which nothing on the page writes, the change is missed.
    @Test(.enabled(if: browserIsAvailable || browserIsRequired))
    func aRouteChangeIsNotMissed() async throws {
        try #require(browserIsAvailable, "\(noBrowser)")
        let server = LocalPageServer(html: identityFixtureHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let tab = try await openLoadedTab(server.url, in: session)
            try await runInPage(tab, "document.getElementById('route').click()")
            let after = await tab.pageIdentity()
            #expect(after.address == server.url + "next")
        }
    }

    /// A reload brings the same address up as a new document, which the site serves again. The
    /// frame's own id survives a reload; the document id must not.
    @Test(.enabled(if: browserIsAvailable || browserIsRequired))
    func aReloadIsNotMissed() async throws {
        try #require(browserIsAvailable, "\(noBrowser)")
        let server = LocalPageServer(html: identityFixtureHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let tab = try await openLoadedTab(server.url, in: session)
            let before = await tab.pageIdentity()
            let beforeId = try #require(before.documentId, "a loaded page read with no document id")
            try await runInPage(tab, "window.__beforeReload = true")
            _ = try await tab.domService.getDebugger().sendCommand("Page", "reload", .object([]))
            let replaced = await documentWasReplaced(tab)
            try #require(replaced, "the reload never brought up a new document")
            let after = await tab.pageIdentity()
            let afterId = try #require(after.documentId, "the reloaded page read with no document id")
            #expect(afterId != beforeId)
        }
    }

    /// An anchor jump scrolls within the page it is on. With the fragment kept in the address, it is
    /// counted as a new page.
    @Test(.enabled(if: browserIsAvailable || browserIsRequired))
    func anAnchorJumpIsNotANewPage() async throws {
        try #require(browserIsAvailable, "\(noBrowser)")
        let server = LocalPageServer(html: identityFixtureHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let tab = try await openLoadedTab(server.url, in: session)
            let before = await tab.pageIdentity()
            let documentId = try #require(before.documentId, "a loaded page read with no document id")
            try await runInPage(tab, "document.getElementById('jump').click()")
            // Without the jump, "nothing changed" would pass for a click that did nothing.
            let hash = try await runInPage(tab, "location.hash").stringValue
            try #require(hash == "#section", "the anchor jump did not happen")
            let after = await tab.pageIdentity()
            #expect(after.address == server.url)
            #expect(after.documentId == documentId)
        }
    }

    /// A page caught between two documents: the one it ran in is gone, the next is not answering
    /// yet. Filled in from the address the tab last cached, the reading says "same page" about a page
    /// that is moving.
    @Test func aPageBetweenDocumentsIsNotReadAsThePageItLeft() async throws {
        let fixture = try await makePageToolsCDPFixture(url: "https://example.com/a")
        let tab = try #require(fixture.tabsService.window?.tabs.tab(fixture.tabId) as? CDPTabHandle)
        fixture.cdp.locationHref = "https://example.com/a"
        fixture.cdp.mainFrameLoaderId = "loader-1"
        // Read settled first, so a `nil` below is not a reader that never reads anything. The tab's
        // cached url is this page, the one it was opened for, so a reader falling back to it lies.
        let settled = await tab.pageIdentity()
        #expect(settled.address == "https://example.com/a")
        #expect(settled.documentId == "loader-1")

        fixture.cdp.navigationCommitting = true
        let moving = await tab.pageIdentity()
        #expect(moving.address == nil)
    }
}

/// Opens `url` in a new tab of `session`'s browser and returns that tab once its page has loaded.
@MainActor
private func openLoadedTab(_ url: String, in session: BrowserToolSession) async throws -> CDPTabHandle {
    let tabs = try #require(await makeCDPBrowserTabsService(client: session.client, seed: false).window).tabs
    let tab = try #require(
        tabs.createTab(TabCreateSpec(tabType: "website", url: url, openedByHuman: false)) as? CDPTabHandle)
    let woke = try await tab.wake(nil)
    try #require(woke.ok, "the page never loaded: \(woke.message ?? "")")
    return tab
}

@MainActor
@discardableResult
private func runInPage(_ tab: CDPTabHandle, _ script: String) async throws -> JSValue {
    try await tab.browserTab.getLayer().executeJavaScript(script)
}

/// Whether the document that set `window.__beforeReload` has been replaced by a loaded one within
/// 10 s. Polled, because an evaluate fails while the two documents swap.
@MainActor
private func documentWasReplaced(_ tab: CDPTabHandle) async -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        let replaced = try? await runInPage(
            tab, "document.readyState === 'complete' && window.__beforeReload === undefined")
        if replaced?.boolValue == true { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}
