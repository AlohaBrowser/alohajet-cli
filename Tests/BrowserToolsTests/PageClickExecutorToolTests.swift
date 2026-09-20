import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - page_click

@Suite("page_click routing (pure)")
struct PageClickRoutingTests {
    @Test func allFourClickTypesRouteToTheirCase() {
        #expect(PageClickExecutorTool.route(for: "single") == .init(call: "click", pendingType: "click"))
        #expect(PageClickExecutorTool.route(for: "double") == .init(call: "doubleClick", pendingType: "doubleClick"))
        #expect(PageClickExecutorTool.route(for: "triple") == .init(call: "tripleClick", pendingType: "tripleClick"))
        #expect(PageClickExecutorTool.route(for: "right") == .init(call: "rightClick", pendingType: "rightClick"))
    }

    /// Negative/edge case: an unrecognized click_type has no route.
    @Test func unknownClickTypeHasNoRoute() {
        #expect(PageClickExecutorTool.route(for: "middle") == nil)
        #expect(PageClickExecutorTool.route(for: "") == nil)
    }
}

@Suite("page_click executor")
@MainActor
struct PageClickExecutorToolTests {
    @Test func requiresAlohaId() async throws {
        let tool = PageClickExecutorTool()
        let context = makePageToolContext(services: nil)
        let result = try await tool.execute(.object(["click_type": .string("single")]), context)
        #expect(result.isError == true)
        #expect(result.output.contains("aloha_id"))
    }

    /// Negative/edge case: an unknown click_type is rejected BEFORE any tab
    /// resolution is attempted (no tabs service wired here at all).
    @Test func unknownClickTypeIsRejectedBeforeTabResolution() async throws {
        let tool = PageClickExecutorTool()
        let context = makePageToolContext(services: nil)
        let result = try await tool.execute(.object([
            "aloha_id": .string("btn-1"), "click_type": .string("middle")
        ]), context)
        #expect(result.isError == true)
        #expect(result.output.contains("click_type"))
    }

    @Test func noActiveTabFailsClearly() async throws {
        let tool = PageClickExecutorTool()
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([]))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(.object(["aloha_id": .string("btn-1")]), makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("no active browser tab"))
    }

    @Test func aTabNobodyTookIsNotDrivenImplicitly() async throws {
        let tool = PageClickExecutorTool()
        let usersTab = PageToolsStubTabHandle(id: "users-tab", url: "https://user.example/", openedByHuman: true)
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([usersTab]))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(.object(["aloha_id": .string("btn-1")]), makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("no active browser tab"))
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let tool = PageClickExecutorTool()
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(.object(["aloha_id": .string("btn-1")]), makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// Click still requires a live DOM. A failed wake must not be skipped the
    /// way page_navigate goto skips it.
    @Test func clickStillRequiresWake() async throws {
        let stubTab = PageToolsStubTabHandle(id: "aloha-default-tab", url: "https://example.com")
        stubTab.wakeResult = WakeResult(
            ok: false,
            message: "Tab \"aloha-default-tab\" is unavailable because it failed to wake: operation exceeded deadline after 18000ms")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "aloha-default-tab"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let tool = PageClickExecutorTool()
        let result = try await tool.execute(
            .object(["aloha_id": .string("btn-1")]),
            makePageToolContext(services: services))
        #expect(stubTab.wakeCalls == 1, "click must still wake")
        #expect(result.isError == true)
        #expect(result.output.contains("unavailable"))
    }

    /// Happy path: a single click on a real (MockCDP-backed) CDP tab reaches
    /// `PageBridge.swift`'s `click` case and dispatches the genuine CDP mouse
    /// sequence — proving the full chain (tab resolution -> bridge construction
    /// -> `executeAgentCode("aloha.click(...)")` -> pending-drain) is wired
    /// correctly, not just the driver method in isolation.
    @Test func singleClickHappyPathDispatchesMouseSequence() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.agentRunnerPendingReply = .object([
            ("result", .null),
            ("error", .null),
            ("pending", .array([
                .object([
                    ("type", .string("click")),
                    ("params", .object([("x", .number(12)), ("y", .number(34)), ("alohaId", .string("btn-1"))]))
                ])
            ]))
        ])
        let tool = PageClickExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object(["aloha_id": .string("btn-1")]), makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("btn-1"))
        // The real backend's cursor animator ALSO emits its own genuine
        // `mouseMoved` ahead of `dispatchClick`'s explicit move -> press ->
        // release sequence, so assert on the trailing press/release pair rather
        // than an exact event count.
        let mouseEvents = fixture.cdp.commands(for: "Input.dispatchMouseEvent")
        let types = mouseEvents.map { $0.params["type"]?.stringValue }
        #expect(types.suffix(2) == ["mousePressed", "mouseReleased"])
        let press = mouseEvents.first { $0.params["type"]?.stringValue == "mousePressed" }
        #expect(press?.params["button"]?.stringValue == "left")
        #expect(press?.params["clickCount"]?.intValue == 1)
    }

    /// Happy path (double-click variant): proves click_type routing reaches the
    /// right pending case end-to-end, not just in the pure `route(for:)` table.
    @Test func doubleClickHappyPathRaisesClickCount() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.agentRunnerPendingReply = .object([
            ("result", .null),
            ("error", .null),
            ("pending", .array([
                .object([
                    ("type", .string("doubleClick")),
                    ("params", .object([("x", .number(1)), ("y", .number(2)), ("alohaId", .string("btn-1"))]))
                ])
            ]))
        ])
        let tool = PageClickExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object([
            "aloha_id": .string("btn-1"), "click_type": .string("double")
        ]), makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("double"))
        let press = fixture.cdp.commands(for: "Input.dispatchMouseEvent").first { $0.params["type"]?.stringValue == "mousePressed" }
        #expect(press?.params["clickCount"]?.intValue == 2)
    }

    /// When the script ran but drained no matching pending op at all (e.g. the
    /// in-page call short-circuited into a different verb), the tool reports a
    /// clear "nothing was dispatched" error rather than a false success.
    @Test func noPendingClickOpIsReportedClearly() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.agentRunnerPendingReply = .object([
            ("result", .null),
            ("error", .null),
            ("pending", .array([]))
        ])
        let tool = PageClickExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object(["aloha_id": .string("btn-1")]), makePageToolContext(services: services))
        await fixture.client.close()
        #expect(result.isError == true)
        #expect(result.output.contains("no click was dispatched"))
    }

    /// The file-input click-refusal guard (`PageBridge.swift`'s
    /// `handleClickPendingRequest`) applies unconditionally on a plain click —
    /// this tool does not bypass it. `executeAgentCode` itself stays
    /// `isError: false` even when the drained pending op failed (see
    /// `AgentBrowserBridge.executeAgentCode`), so the refusal ONLY surfaces via
    /// the per-op `PendingResult`, which `interpret(_:route:alohaId:clickType:)`
    /// is what must translate into a tool-level error.
    @Test func fileInputClickRefusalSurfacesAsToolError() {
        let scriptSucceeded = AgentActionResult(
            output: "Code executed successfully.\n\nResult:\nundefined",
            isError: false,
            pendingResults: [PendingResult(type: "click", success: false, error: fileInputClickRefusalMessage)]
        )
        let route = PageClickExecutorTool.route(for: "single")!
        let toolResult = PageClickExecutorTool.interpret(scriptSucceeded, route: route, alohaId: "file-1", clickType: "single")
        #expect(toolResult.isError == true)
        #expect(toolResult.output == fileInputClickRefusalMessage)
        #expect(toolResult.output.contains("file picker"))
    }

    // MARK: - Receipt states the page delta

    /// `Clicked element "2s" (single).` is true of a click that navigated, one that opened a menu, and
    /// one that hit nothing — and 44 rows of the WebArena read-tier corpus answered the task
    /// immediately after a receipt of exactly that shape. These pin the three cases the receipt must
    /// distinguish, including the one where it must stay quiet.
    @Test func receiptSaysThePageDidNotNavigate() {
        let delta = PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/a")
        #expect(delta.contains("did NOT navigate"))
        #expect(delta.contains("http://host/a"))
    }

    @Test func receiptNamesTheNewPage() {
        let delta = PageDelta.describe(urlBefore: "http://host/a", urlAfter: "http://host/b")
        #expect(delta.contains("Navigated to http://host/b"))
        #expect(!delta.contains("did NOT"))
    }

    /// A receipt that claimed "did not navigate" when it merely could not READ the url would be worse
    /// than the bare receipt it replaces: the navigation seam is optional and some backends return "".
    @Test func unknownUrlSaysNothingRatherThanGuessing() {
        #expect(PageDelta.describe(urlBefore: "http://host/a", urlAfter: "") == "")
        #expect(PageDelta.describe(urlBefore: "", urlAfter: "") == "")
    }

    /// First action of a run: nothing to compare against, so state where the page is without implying
    /// a comparison that was never made.
    @Test func noBeforeUrlStatesTheCurrentPageOnly() {
        #expect(PageDelta.describe(urlBefore: "", urlAfter: "http://host/b")
                == " Now at http://host/b.")
    }

    /// The delta rides on the SUCCESS receipt only — a refused or failed click keeps its own message.
    @Test func successfulClickReceiptCarriesTheDelta() {
        let route = PageClickExecutorTool.route(for: "single")!
        let succeeded = AgentActionResult(
            output: "Code executed successfully.", isError: false,
            pendingResults: [PendingResult(type: "click", success: true, error: nil)])
        let result = PageClickExecutorTool.interpret(
            succeeded, route: route, alohaId: "2s", clickType: "single",
            urlBefore: "http://host/a", urlAfter: "http://host/a")
        #expect(result.output.contains("Clicked element \"2s\" (single)."))
        #expect(result.output.contains("did NOT navigate"))
    }

}

// MARK: - The runner script must not ask the page to compile a string

/// A strict Content Security Policy made `page_click` unusable on a whole site.
///
/// MEASURED 2026-08-06 across four run files: 19 WebArena rows carry
/// `Refused to evaluate a string as JavaScript because 'unsafe-eval' ... is not an allowed source of
/// script`, 14 of them failures, and EVERY ONE is `site=reddit` — whose Postmill instance ships
/// `script-src 'self' 'unsafe-inline'` with no `unsafe-eval`. The refusal comes from
/// `buildAgentCodeRunnerScript`'s `new Function(...)`, not from CDP evaluation itself, and the click
/// path never needed dynamic compilation: its script is `aloha.click("2s")`, built in Swift from a
/// typed click_type and a quoted id.
///
/// reddit is one of the four sites the team's official stand hosts, so this is one of the few Jet fixes
/// that can move the shared metric as well as ours.
@Suite("agent-code runner compilation")
struct AgentCodeRunnerCompilationTests {
    @Test func theInlinePathNeverCompilesAStringInThePage() {
        let script = buildAgentCodeRunnerScript("aloha.click(\"2s\")", compile: .inline)
        #expect(!script.contains("new Function"))
        #expect(script.contains("aloha.click(\"2s\")"))
        #expect(script.contains("Nothing is compiled from a"))
    }

    @Test func theDynamicPathStillCompilesForModelAuthoredCode() {
        // The dynamic arm exists for model-authored source, which cannot be inlined. No tool
        // in this package reaches it — the eight all pass `compile: .inline` — but the branch
        // is still in the runner, so its behaviour is pinned rather than assumed.
        let script = buildAgentCodeRunnerScript("return document.title", compile: .dynamic)
        #expect(script.contains("new Function"))
        #expect(script.contains("__agentFn(aloha, __aloha)"))
    }

    @Test func dynamicIsStillTheDefault() {
        #expect(buildAgentCodeRunnerScript("return 1").contains("new Function"))
    }

    /// Both paths must keep the pending-drain bookkeeping the bridge reads back, or a click would
    /// dispatch and its host-side `Input.*` op would never be drained.
    @Test func bothPathsKeepThePendingContract() {
        for script in [buildAgentCodeRunnerScript("aloha.click(\"2s\")", compile: .inline),
                       buildAgentCodeRunnerScript("aloha.click(\"2s\")", compile: .dynamic)] {
            #expect(script.contains("window.__alohaPending = __runPending"))
            #expect(script.contains("return { result: __rawResult, error: __execError, pending: __runPending }"))
        }
    }
}
