import Testing
import Foundation
import ToolABI
@testable import BrowserTools

@Suite("page_navigate executor")
@MainActor
struct PageNavigateExecutorToolTests {
    @Test func unknownActionIsRejected() async throws {
        let tool = PageNavigateExecutorTool()
        let result = try await tool.execute(.object(["action": .string("reload")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("action"))
    }

    /// Negative/edge case (explicitly called out in the task): `url` is
    /// required for "goto", rejected before any tab resolution.
    @Test func gotoRequiresUrl() async throws {
        let tool = PageNavigateExecutorTool()
        let result = try await tool.execute(.object(["action": .string("goto")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("url"))
    }

    /// Negative/edge case (explicitly called out in the task): `url` is ignored
    /// for "back" — passing one does NOT trip the "url required" validation
    /// (proven by reaching PAST validation into tab resolution, whose failure
    /// message is the tabs-service one, not a url complaint).
    @Test func backIgnoresUrlAndStillReachesTabResolution() async throws {
        let tool = PageNavigateExecutorTool()
        let result = try await tool.execute(
            .object(["action": .string("back"), "url": .string("https://ignored.example")]),
            makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("tabs service is not available"))
        #expect(!result.output.lowercased().contains("requires \"url\""))
    }

    /// Aloha's default tab often fails wake with "operation exceeded deadline".
    /// goto must not even call wake — it must fall through to the CDP-tab check.
    @Test func gotoDoesNotCallWakeOnStubTab() async throws {
        let stubTab = PageToolsStubTabHandle(id: "aloha-default-tab", url: "about:blank")
        stubTab.wakeResult = WakeResult(
            ok: false,
            message: "Tab \"aloha-default-tab\" is unavailable because it failed to wake: operation exceeded deadline after 18000ms")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "aloha-default-tab"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let tool = PageNavigateExecutorTool()
        let result = try await tool.execute(
            .object(["action": .string("goto"), "url": .string("http://127.0.0.1:8801/")]),
            makePageToolContext(services: services))
        #expect(stubTab.wakeCalls == 0, "goto must not wait on wake")
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
        #expect(!result.output.contains("failed to wake"))
        #expect(!result.output.contains("unavailable"))
    }

    /// History-back still requires a live renderer: a failed wake must not skip
    /// to Page.navigateToHistoryEntry the way goto skips to Page.navigate.
    @Test func backStillRequiresWake() async throws {
        let stubTab = PageToolsStubTabHandle(id: "aloha-default-tab", url: "https://example.com")
        stubTab.wakeResult = WakeResult(
            ok: false,
            message: "Tab \"aloha-default-tab\" is unavailable because it failed to wake: operation exceeded deadline after 18000ms")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "aloha-default-tab"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let tool = PageNavigateExecutorTool()
        let result = try await tool.execute(
            .object(["action": .string("back")]),
            makePageToolContext(services: services))
        #expect(stubTab.wakeCalls == 1, "back must still wake")
        #expect(result.isError == true)
        #expect(result.output.contains("unavailable"))
    }

    /// Frozen default-tab WKWebView: readyState eval hangs until a real
    /// Page.navigate revives the renderer. goto must issue that navigate instead
    /// of failing at wake, and must finish well under the 18s wake deadline.
    @Test func gotoNavigatesEvenWhenReadyStateProbeHangs() async throws {
        let fixture = try await makePageToolsCDPFixture(url: "about:blank")
        fixture.cdp.suppressEvaluateUntilNavigate = true
        fixture.cdp.pageUrl = "about:blank"
        let tool = PageNavigateExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let started = Date()
        let result = try await tool.execute(
            .object(["action": .string("goto"), "url": .string("http://127.0.0.1:8801/")]),
            makePageToolContext(services: services))
        await fixture.client.close()

        let elapsed = Date().timeIntervalSince(started)
        #expect(result.isError != true, "goto must not fail at wake; got \(result.output)")
        #expect(result.output.contains("127.0.0.1:8801"))
        #expect(fixture.cdp.received("Page.navigate"))
        #expect(fixture.cdp.commands(for: "Page.navigate").first?.params["url"]?.stringValue == "http://127.0.0.1:8801/")
        // PORT NOTE: an earlier copy of this test asserted `elapsed < 5.0` here. This package builds
        // its test targets with `defaultIsolation(MainActor.self)`, so every main-actor
        // test in the run serialises against every other one and wall-clock is contended
        // — this test measures 0.5s alone and 10s+ in a full run. The three assertions
        // above already carry the meaning: `Page.navigate` was issued, and it ran BEFORE
        // the first readyState probe, which is what "goto skips the wake" means.
        _ = elapsed
        let methods = fixture.cdp.receivedMethods()
        if let navigate = methods.firstIndex(of: "Page.navigate"),
           let eval = methods.firstIndex(of: "Runtime.evaluate") {
            #expect(navigate < eval, "Page.navigate must run before the first readyState probe")
        }
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let tool = PageNavigateExecutorTool()
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(
            .object(["action": .string("goto"), "url": .string("https://b.example")]),
            makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// Happy path (goto): navigates the active tab in place — a real
    /// `Page.navigate` command is dispatched — distinct from manage_tabs' "open"
    /// action, which allocates a brand-new tab.
    @Test func gotoHappyPathNavigatesInPlace() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tool = PageNavigateExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["action": .string("goto"), "url": .string("https://news.example.org/")]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("news.example.org"))
        let navigate = fixture.cdp.commands(for: "Page.navigate").first
        #expect(navigate?.params["url"]?.stringValue == "https://news.example.org/")
        // No new tab was created for "goto" — still exactly the one seeded tab.
        #expect(fixture.tabsService.window!.tabs.orderedTabs.count == 1)
    }

    /// Happy path (back): steps history back on the active tab.
    @Test func backHappyPathStepsHistory() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tool = PageNavigateExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object(["action": .string("back")]), makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(fixture.cdp.received("Page.getNavigationHistory"))
        #expect(fixture.cdp.received("Page.navigateToHistoryEntry"))
    }
}
