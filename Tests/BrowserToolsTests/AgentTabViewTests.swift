import Foundation
import Testing
import ToolABI
import CDP
@testable import BrowserTools

// The agent's view of open tabs (docs_baych `tab_attribution/agent_tab_view/DESIGN.md`,
// section 10): at every listing the tabs model is the browser's list, with the browser's
// values; the page-load wait expects only the page the agent asked for; and a blank tab is
// shown only while it is in front or in use.

@MainActor private final class FakeAttributionSource: TabAttributionSource {
    var foregroundTabId: String?
}

@MainActor private func seededModel(
    _ cdp: MockCDP, source: TabAttributionSource? = nil
) async throws -> CDPTabsModel {
    let channel = cdp.channel()
    let client = CDPClient(channel: channel)
    try await client.connect()
    let service = await makeCDPBrowserTabsService(client: client, attributionSource: source)
    return try #require(service.window?.tabs as? CDPTabsModel)
}

@Test @MainActor func aTabTheListingNoLongerNamesLeavesTheList() async throws {
    let cdp = MockCDP()
    cdp.addTarget(id: "A", url: "https://a.example/")
    cdp.addTarget(id: "B", url: "https://b.example/")
    let tabs = try await seededModel(cdp)
    tabs.setActiveTabId("B")
    // What a page tool resolved before the listing, and still holds.
    let held = try #require(tabs.tab("B"))

    cdp.removeTarget(id: "B")
    await tabs.refreshAndAdoptTabs()

    #expect(tabs.orderedTabs.map(\.id) == ["A"])
    #expect(tabs.tab("B") == nil)
    #expect(tabs.activeTabId == nil)
    // The held handle fails on its own, before it asks the browser anything: on the desktop,
    // a command under a closed tab's id was answered by the tab in front (run 1).
    let heldWake = try await held.wake(nil)
    #expect(!heldWake.ok)
    #expect(cdp.commands(for: "Target.attachToTarget").isEmpty)
}

@Test @MainActor func aTrackedTabTakesTheListingsAddressAndTitleVerbatim() async throws {
    let cdp = MockCDP()
    cdp.addTarget(id: "A", url: "https://example.com/", title: "Example Domain")
    let tabs = try await seededModel(cdp)

    // The user pressed Home: the browser lists the start page.
    cdp.addTarget(id: "A", url: "about:blank", title: "")
    await tabs.refreshAndAdoptTabs()

    let tab = try #require(tabs.tab("A"))
    #expect(tab.url == "about:blank")
    #expect(tab.title == "")
}

@Test @MainActor func theLoadWaitExpectsOnlyThePageTheAgentAskedFor() async throws {
    let cdp = MockCDP()
    cdp.addTarget(id: "A", url: "https://example.com/", title: "Example Domain")
    cdp.pageUrl = "about:blank"
    cdp.pageTitle = ""
    let tabs = try await seededModel(cdp)

    // Remembered at a real page, showing a blank one, nothing asked for: the blank document
    // is the page, and the wake takes it as it is.
    let seeded = try #require(tabs.tab("A"))
    let seededWake = try await seeded.wake(nil)
    #expect(seededWake.ok)
    #expect(seeded.url == "about:blank")

    // Opened for a page: its blank first document is that page still arriving, so the wake
    // waits until the page itself is there.
    let opened = tabs.createTab(TabCreateSpec(tabType: "website", url: "https://example.org/", owner: .chat("c")))
    let arrival = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 600_000_000)
        cdp.pageUrl = "https://example.org/"
        cdp.pageTitle = "Example Org"
    }
    let openedWake = try await opened.wake(nil)
    await arrival.value
    #expect(openedWake.ok)
    #expect(opened.url == "https://example.org/")

    // That wait is over, and the request with it: when the user then presses Home, the
    // blank start page is the page, as it is for a tab the agent never asked anything of.
    cdp.pageUrl = "about:blank"
    cdp.pageTitle = ""
    let afterHomeWake = try await opened.wake(nil)
    #expect(afterHomeWake.ok)
    #expect(opened.url == "about:blank")
}

@Test @MainActor func aBlankTabIsShownOnlyInFrontOrInUse() async throws {
    let cdp = MockCDP()
    cdp.addTarget(id: "A", url: "https://a.example/", title: "A")
    cdp.addTarget(id: "B", url: "about:blank")
    cdp.addTarget(id: "C", url: "about:blank")
    let source = FakeAttributionSource()
    let tabs = try await seededModel(cdp, source: source)
    let window = CDPTabsWindow(id: "window", model: tabs)
    func shown() -> Set<String> {
        Set((manageTabsList(window, nil, askingChat: "c").tabs ?? []).map(\.id))
    }
    // The list's first line: its count, which must never be smaller than the tab strip
    // without saying why (R8: "1 tab(s) open" told to a user with three tabs).
    func countLine() -> String {
        (manageTabsList(window, nil, askingChat: "c").output ?? "").components(separatedBy: "\n")[0]
    }

    source.foregroundTabId = "B"
    #expect(shown() == ["A", "B"])
    #expect(countLine() == "2 tab(s) open (1 empty tab not shown):")

    source.foregroundTabId = "A"
    #expect(shown() == ["A"])
    #expect(countLine() == "1 tab(s) open (2 empty tabs not shown):")

    tabs.setActiveTabId("C")
    #expect(shown() == ["A", "C"])
    #expect(countLine() == "2 tab(s) open (1 empty tab not shown):")

    // Nothing hidden: the count line is what it always was.
    source.foregroundTabId = "B"
    #expect(shown() == ["A", "B", "C"])
    #expect(countLine() == "3 tab(s) open:")
}
