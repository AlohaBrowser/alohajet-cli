import Testing
import Foundation
import ToolABI
@testable import BrowserTools

@Suite("page_select executor")
@MainActor
struct PageSelectExecutorToolTests {
    @Test func requiresAlohaId() async throws {
        let tool = PageSelectExecutorTool()
        let result = try await tool.execute(.object(["text": .string("France")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("aloha_id"))
    }

    /// Negative/edge case (explicitly called out in the task): neither `text`
    /// nor `index` is a clear validation error, rejected before any tab
    /// resolution.
    @Test func neitherTextNorIndexIsRejected() async throws {
        let tool = PageSelectExecutorTool()
        let result = try await tool.execute(.object(["aloha_id": .string("country")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("text") && result.output.contains("index"))
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let tool = PageSelectExecutorTool()
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(
            .object(["aloha_id": .string("country"), "text": .string("France")]),
            makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// Happy path: selecting by visible text on a real (MockCDP-backed) tab
    /// reaches `window.__aloha.select(...)` and reports the selected label.
    @Test func selectByTextHappyPath() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.alohaRawCallReplies = [(
            match: "__aloha.select(",
            reply: .object([
                ("success", .bool(true)),
                ("selected", .object([("value", .string("fr")), ("label", .string("France"))]))
            ])
        )]
        let tool = PageSelectExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["aloha_id": .string("country"), "text": .string("France")]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("France"))
    }

    /// Happy path (index variant): selecting by zero-based index.
    @Test func selectByIndexHappyPath() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.alohaRawCallReplies = [(
            match: "__aloha.select(",
            reply: .object([
                ("success", .bool(true)),
                ("selected", .object([("value", .string("m")), ("label", .string("Medium"))]))
            ])
        )]
        let tool = PageSelectExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["aloha_id": .string("size"), "index": .number(1)]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("Medium"))
    }
}
