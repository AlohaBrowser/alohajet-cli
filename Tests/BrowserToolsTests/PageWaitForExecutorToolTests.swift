import Testing
import Foundation
import ToolABI
@testable import BrowserTools

@Suite("page_wait_for executor")
@MainActor
struct PageWaitForExecutorToolTests {
    @Test func requiresSelector() async throws {
        let tool = PageWaitForExecutorTool()
        let result = try await tool.execute(.object([:]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("selector"))
    }

    @Test func emptySelectorIsRejected() async throws {
        let tool = PageWaitForExecutorTool()
        let result = try await tool.execute(.object(["selector": .string("")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let tool = PageWaitForExecutorTool()
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(.object(["selector": .string(".ready")]), makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// Happy path: waits for a selector on a real (MockCDP-backed) tab using
    /// the default 10s timeout, reaching `window.__aloha.waitFor(...)`.
    @Test func waitForHappyPathUsesDefaultTimeout() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.waitFor(", reply: .object([("success", .bool(true))]))]
        let tool = PageWaitForExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object(["selector": .string(".ready")]), makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains(".ready"))
        let waitForCall = fixture.cdp.commands(for: "Runtime.evaluate")
            .compactMap { $0.params["expression"]?.stringValue }
            .first { $0.contains("__aloha.waitFor(") }
        #expect(waitForCall?.contains("10000") == true)
    }

    /// Negative/edge case (timeout path): a `timeout_ms` above the 30s cap is
    /// CLAMPED — the exact value that actually reaches the page is 30000, never
    /// the raw oversized request — proven end-to-end through the tool, not just
    /// at the driver (`AgentBrowserBridge.waitForSelector`, already covered by
    /// `PageToolsBridgeMethodsTests`). The genuine timeout-EXPIRY rejection path
    /// (the MutationObserver's `reject(new Error('waitFor timeout: ...'))`) is
    /// covered there too (`waitForSelectorTimeoutExpirySurfacesAsError`), since
    /// `MockCDP` has no hook to script a thrown `Runtime.evaluate` exception.
    @Test func timeoutAboveCapIsClamped() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.waitFor(", reply: .object([("success", .bool(true))]))]
        let tool = PageWaitForExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["selector": .string(".x"), "timeout_ms": .number(999_999)]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        let waitForCall = fixture.cdp.commands(for: "Runtime.evaluate")
            .compactMap { $0.params["expression"]?.stringValue }
            .first { $0.contains("__aloha.waitFor(") }
        #expect(waitForCall?.contains("30000") == true)
        #expect(waitForCall?.contains("999999") == false)
    }
}
