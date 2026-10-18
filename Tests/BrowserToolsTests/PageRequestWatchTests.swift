import Testing
import Foundation
import ToolABI
import CDP
@testable import BrowserTools

// MARK: - Is the page still waiting for its answer?
//
// github-ss-r54 (2026-09-28): a replay clicked GitHub's "Go" language filter, the page swapped its
// list for a loading state and then held still while ONE fetch was in flight; the DOM-quiet rule
// called that settled and the next steps were planned against the old list. The counting rule is
// ported from the agent repository (windows-on-snips `RequestAwareSettleTests`); the watch over a
// tab's CDP session is checked against MockCDP.

@Suite("Page request counter")
struct PageRequestCounterTests {
    private func sent(_ id: String, _ type: String, _ url: String, accept: String? = nil) -> JSValue {
        var request: [(String, JSValue)] = [("url", .string(url))]
        if let accept { request.append(("headers", .object([("Accept", .string(accept))]))) }
        return .object([("requestId", .string(id)), ("type", .string(type)), ("request", .object(request))])
    }
    private func finished(_ id: String) -> JSValue { .object([("requestId", .string(id))]) }

    @Test func fetchesXhrsAndDocumentsCountUntilAnswered() {
        let counter = PageRequestCounter()
        counter.handle(method: "Network.requestWillBeSent", params: sent("1", "Fetch", "https://github.com/search?q=x&l=Go"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("2", "XHR", "https://site.example/api"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("3", "Document", "https://site.example/next"))
        #expect(counter.inFlight() == 3)
        counter.handle(method: "Network.loadingFinished", params: finished("1"))
        counter.handle(method: "Network.loadingFailed", params: finished("2"))
        #expect(counter.inFlight() == 1)
        counter.handle(method: "Network.loadingFinished", params: finished("3"))
        #expect(counter.inFlight() == 0)
    }

    /// What the r54 click also sent, none of which changes what the page shows.
    @Test func imagesBeaconsScriptsAndStreamsAreNotCounted() {
        let counter = PageRequestCounter()
        counter.handle(method: "Network.requestWillBeSent", params: sent("a", "Image", "https://github.com/x.png?size=40"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("b", "Ping", "https://collector.github.com/github/collect"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("c", "Script", "https://site.example/app.js"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("d", "Fetch", "https://site.example/events", accept: "text/event-stream"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("e", "XHR", "https://site.example/long-poll"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("f", "Fetch", "https://www.google-analytics.com/g/collect"))
        counter.handle(method: "Network.requestWillBeSent", params: sent("g", "Fetch", "data:text/plain,x"))
        #expect(counter.inFlight() == 0)
    }

    @Test func anUnrelatedEventOrAFinishForAnUnknownIdChangesNothing() {
        let counter = PageRequestCounter()
        counter.handle(method: "Network.requestWillBeSent", params: sent("1", "Fetch", "https://site.example/api"))
        counter.handle(method: "Page.frameNavigated", params: .object([]))
        counter.handle(method: "Network.loadingFinished", params: finished("zzz"))
        #expect(counter.inFlight() == 1)
    }
}

@Suite("Page request watch on a tab")
@MainActor
struct PageRequestWatchTests {
    private func sent(_ id: String, _ type: String = "Fetch", _ url: String = "https://example.com/api") -> JSValue {
        .object([("requestId", .string(id)), ("type", .string(type)), ("request", .object([("url", .string(url))]))])
    }

    /// Polls until `condition` holds; events reach the watch through the client's receive loop and
    /// a detached task, so the count follows the emission a moment later.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func cdpTab(_ fixture: PageToolsCDPFixture) throws -> CDPTabHandle {
        let window = try #require(fixture.tabsService.window)
        return try #require(window.tabs.tab(fixture.tabId) as? CDPTabHandle)
    }

    /// The watch enables `Network` on the tab's own session, counts the fetch the page sends after
    /// it started, and lets it go when the answer arrives.
    @Test func aFetchIsInFlightUntilItsAnswerArrives() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        let watch = try #require(await cdpTab(fixture).startPageRequestWatch())
        defer { watch.stop() }
        let enable = try #require(fixture.cdp.commands(for: "Network.enable").last)
        let session = try #require(fixture.cdp.currentSessionId())
        #expect(enable.sessionId == session)

        #expect(watch.inFlight() == 0)
        fixture.cdp.emitEvent(method: "Network.requestWillBeSent", params: sent("r1"))
        fixture.cdp.emitEvent(method: "Network.requestWillBeSent", params: sent("img", "Image", "https://example.com/a.png"))
        #expect(await eventually { watch.inFlight() == 1 })
        fixture.cdp.emitEvent(method: "Network.loadingFinished", params: .object([("requestId", .string("r1"))]))
        #expect(await eventually { watch.inFlight() == 0 })
    }

    /// Another session's requests are another page's: not counted.
    @Test func anotherSessionsRequestsAreNotCounted() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        let watch = try #require(await cdpTab(fixture).startPageRequestWatch())
        defer { watch.stop() }
        fixture.cdp.emitEvent(method: "Network.requestWillBeSent", params: sent("other"), sessionId: "session-elsewhere")
        fixture.cdp.emitEvent(method: "Network.requestWillBeSent", params: sent("mine"))
        #expect(await eventually { watch.inFlight() == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(watch.inFlight() == 1)
    }

    /// After `stop()` nothing more is counted, and a second stop is harmless.
    @Test func aStoppedWatchCountsNothingMore() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        let watch = try #require(await cdpTab(fixture).startPageRequestWatch())
        fixture.cdp.emitEvent(method: "Network.requestWillBeSent", params: sent("a"))
        #expect(await eventually { watch.inFlight() == 1 })
        watch.stop()
        watch.stop()
        try? await Task.sleep(for: .milliseconds(20))
        fixture.cdp.emitEvent(method: "Network.requestWillBeSent", params: sent("b"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(watch.inFlight() == 1)
    }

    /// A closed tab has no page to watch.
    @Test func aClosedTabHasNoWatch() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        let tab = try cdpTab(fixture)
        _ = try await tab.wake(nil)
        let window = try #require(fixture.tabsService.window)
        await window.tabs.closeTab(fixture.tabId, skipConfirm: true)
        #expect(await tab.startPageRequestWatch() == nil)
    }
}
