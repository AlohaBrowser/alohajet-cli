import Testing
import Foundation
import ToolABI
@testable import BrowserTools

@Suite("get_text executor")
@MainActor
struct GetTextExecutorToolTests {
    @Test func requiresAlohaId() async throws {
        let tool = GetTextExecutorTool()
        let result = try await tool.execute(.object([:]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("aloha_id"))
    }

    /// Negative/edge case: an empty-string aloha_id is treated the same as
    /// absent (rejected before any tab resolution).
    @Test func emptyAlohaIdIsRejected() async throws {
        let tool = GetTextExecutorTool()
        let result = try await tool.execute(.object(["aloha_id": .string("")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let tool = GetTextExecutorTool()
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(.object(["aloha_id": .string("headline")]), makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// Happy path: reads text from a real (MockCDP-backed) tab via
    /// `window.__aloha.getText(...)`.
    @Test func getTextHappyPath() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.getText(", reply: .string("Welcome back"))]
        let tool = GetTextExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object(["aloha_id": .string("headline")]), makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output == "Welcome back")
    }
}
