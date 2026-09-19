import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// EVERY ACTION RETURNS THE PAGE IT LEFT BEHIND -- and only when it left a different one.
//
// A receipt alone (`Clicked element "2s" (single).`) says nothing about what the click did to
// the page, so the model spends a round on `manage_tabs read` before it can act again, or acts
// on ids from the page BEFORE the click. Measured on WebArena run 34366647873 over 579
// `page_type` calls: 36% came back with a page, 39% with a bare receipt, against 65% for
// `page_click`; "answered without looking" was 64 of 199 answer turns.
//
// The gate is `pageFingerprint` -- document generation, element count, URL -- read either side
// of the action. Re-sending an unchanged page costs a DOM walk and rides in the model's context
// for every remaining round (33k tokens against 27k, measured). Typing is exempt: a typed value
// moves none of the three, and confirming it is the whole point of sending the page.

// MARK: - Fakes

/// The `ChatModeSession` the snapshot read needs; without one the read is skipped on purpose.
@MainActor private final class SnapshotSession: ChatModeSession {
    var active: String?
    func sessionNetworkDir() -> String? { nil }
    func registerNetworkRecordingTab(_ tab: TabHandle) {}
    func unregisterNetworkRecordingTab(_ tabId: String) {}
    func setActiveBrowserTab(_ tabId: String?) { active = tabId }
    func getActiveBrowserTabId() -> String? { active }
    func clearActiveBrowserTabIfMatches(_ tabId: String) { if active == tabId { active = nil } }
}

/// Whether the mock saw the DOM walker run -- the one `Runtime.evaluate` a page read cannot
/// avoid. Recognised the way `MockCDP` itself recognises it, by the walker's entry point.
@MainActor private func pageWasRead(_ cdp: MockCDP) -> Bool {
    cdp.commands(for: "Runtime.evaluate").contains { $0.params["expression"]?.stringValue?.contains("buildDomTree(") == true }
}

private let clickReply: JSValue = .object([
    ("result", .null),
    ("error", .null),
    ("pending", .array([
        .object([
            ("type", .string("click")),
            ("params", .object([("x", .number(12)), ("y", .number(34)), ("alohaId", .string("btn-1"))]))
        ])
    ]))
])

// MARK: - Bridge level

@Suite("pageFingerprint")
@MainActor
struct PageFingerprintTests {
    @Test func isTheThreePartStringThePageReturns() async {
        let backend = PageToolsRecordingBackend()
        backend.evaluateResult = .string("7ff8|1267|https://example.com/x")
        let bridge = AgentBrowserBridge(backend: backend)
        #expect(await bridge.pageFingerprint() == "7ff8|1267|https://example.com/x")
        // One evaluate, no DOM walk, no agent-code wrapper: this is meant to be cheap.
        #expect(backend.capturedScripts.count == 1)
        #expect(backend.capturedScripts[0].contains("__alohaDocGeneration"))
        #expect(!backend.capturedScripts[0].contains("buildDomTree("))
    }

    @Test func isNilWhenThePageCannotAnswer() async {
        let throwing = PageToolsRecordingBackend()
        throwing.evaluateError = SimpleBrowserError("Execution context was destroyed")
        #expect(await AgentBrowserBridge(backend: throwing).pageFingerprint() == nil)

        let empty = PageToolsRecordingBackend()
        empty.evaluateResult = .string("")
        #expect(await AgentBrowserBridge(backend: empty).pageFingerprint() == nil)
    }

    @Test func aNilOnEitherSideCountsAsMoved() {
        // An unreadable page must never be mistaken for one that did not change: that would
        // silently drop the snapshot exactly when the page is mid-navigation.
        #expect(AgentBrowserBridge.pageMoved(before: nil, after: "a|1|u"))
        #expect(AgentBrowserBridge.pageMoved(before: "a|1|u", after: nil))
        #expect(AgentBrowserBridge.pageMoved(before: nil, after: nil))
        #expect(AgentBrowserBridge.pageMoved(before: "a|1|u", after: "a|2|u"))
        #expect(!AgentBrowserBridge.pageMoved(before: "a|1|u", after: "a|1|u"))
    }
}

// MARK: - Tool level, through the mock browser

@Suite("the page an action left behind")
@MainActor
struct PageAfterActionTests {
    /// The mock answers every unscripted evaluate with the same body text, so the fingerprint
    /// reads identical either side of the click: the page did not move, and the DOM walk must
    /// not be spent. This is the common case on a grid page, and the reason the gate exists.
    @Test func aClickOnAnUnchangedPageReadsNoPage() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.agentRunnerPendingReply = clickReply
        let services = NativeToolServices(tabsService: fixture.tabsService, session: SnapshotSession())
        let result = try await PageClickExecutorTool().execute(
            .object(["aloha_id": .string("btn-1")]), makePageToolContext(services: services))
        await fixture.client.close()
        #expect(result.isError != true)
        #expect(result.output.hasPrefix("Clicked element \"btn-1\""))
        #expect(!pageWasRead(fixture.cdp), "an unchanged page must not cost a DOM walk")
    }

    /// A navigation replaced the page by definition, so the read is attempted unconditionally.
    /// Whether the mock can SERVE a page is not the question here -- it answers the walker with
    /// a string and the read fails closed, leaving the receipt alone -- the question is that the
    /// tool asked.
    @Test func aNavigationAlwaysAttemptsThePage() async throws {
        let fixture = try await makePageToolsCDPFixture(url: "about:blank")
        fixture.cdp.pageUrl = "about:blank"
        let services = NativeToolServices(tabsService: fixture.tabsService, session: SnapshotSession())
        let result = try await PageNavigateExecutorTool().execute(
            .object(["action": .string("goto"), "url": .string("http://127.0.0.1:8801/")]),
            makePageToolContext(services: services))
        await fixture.client.close()
        #expect(result.isError != true, "goto must still succeed; got \(result.output)")
        #expect(pageWasRead(fixture.cdp), "a navigation must attempt to attach the page it landed on")
        // And a read the mock could not serve leaves the receipt exactly as it was.
        #expect(result.output.contains("127.0.0.1:8801"))
    }

    /// No session, no read: the snapshot is an addition to a receipt, never a reason to fail one,
    /// and a host that wires no session gets the pre-existing behaviour byte for byte.
    @Test func withoutASessionNoPageIsRead() async throws {
        let fixture = try await makePageToolsCDPFixture(url: "about:blank")
        fixture.cdp.pageUrl = "about:blank"
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await PageNavigateExecutorTool().execute(
            .object(["action": .string("goto"), "url": .string("http://127.0.0.1:8801/")]),
            makePageToolContext(services: services))
        await fixture.client.close()
        #expect(result.isError != true)
        #expect(!pageWasRead(fixture.cdp))
    }

    /// An errored receipt is returned untouched, and so is one whose page did not change: the
    /// action did not happen, or changed nothing, and a failure is not where a DOM walk is spent.
    @Test func anErroredOrUnchangedReceiptIsNeverEnriched() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let services = NativeToolServices(tabsService: fixture.tabsService, session: SnapshotSession())
        let context = makePageToolContext(services: services)
        let tab = try #require(fixture.tabsService.window?.tabs.getOrRestoreTab(fixture.tabId, restoreIfNeeded: false))
        let cdpTab = try #require(tab as? CDPTabHandle)
        let resolved = ResolvedPageTab(tab: tab, cdpTab: cdpTab)

        let failed = RawToolResult(output: "page_click failed: no click was dispatched.", isError: true)
        let afterFailure = await withPageSnapshot(failed, context, resolved, changed: true)
        #expect(afterFailure.output == failed.output)
        #expect(afterFailure.isError == true)

        let unchanged = RawToolResult(output: "Clicked element \"btn-1\" (single).", isError: nil)
        let afterNoChange = await withPageSnapshot(unchanged, context, resolved, changed: false)
        #expect(afterNoChange.output == unchanged.output)
        await fixture.client.close()
        #expect(!pageWasRead(fixture.cdp), "neither case may spend a DOM walk")
    }
}
