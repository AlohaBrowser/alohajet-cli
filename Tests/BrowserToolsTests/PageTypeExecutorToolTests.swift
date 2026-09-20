import Testing
import Foundation
import ToolABI
@testable import BrowserTools

@Suite("page_type executor")
@MainActor
struct PageTypeExecutorToolTests {
    @Test func requiresAlohaId() async throws {
        let tool = PageTypeExecutorTool()
        let result = try await tool.execute(.object(["text": .string("hi")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("aloha_id"))
    }

    /// Negative/edge case: `text` is required — omitting it is rejected before
    /// any tab resolution is attempted.
    @Test func requiresText() async throws {
        let tool = PageTypeExecutorTool()
        let result = try await tool.execute(.object(["aloha_id": .string("field-1")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("text"))
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let tool = PageTypeExecutorTool()
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(
            .object(["aloha_id": .string("field-1"), "text": .string("hi")]),
            makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// Happy path: types into a real (MockCDP-backed) tab and rides genuine CDP
    /// key events — the same dispatch `BridgeInteractionActionsTests` already
    /// proves at the pending-request layer; this proves the tool's OWN
    /// resolve-tab -> call-`AgentBrowserBridge.type`-directly wiring reaches it.
    @Test func typeHappyPathDispatchesKeyEvents() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tool = PageTypeExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["aloha_id": .string("field-1"), "text": .string("hi")]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("field-1"))
        // replace defaults to true, so a Backspace clear (down/up) rides first,
        // then "hi" — two printable ASCII chars — as 4 more dispatchKeyEvent
        // calls (down/up each): 2 + 4 = 6 total.
        let keyEvents = fixture.cdp.commands(for: "Input.dispatchKeyEvent")
        #expect(keyEvents.count == 6)
        #expect(keyEvents.filter { $0.params["key"]?.stringValue == "Backspace" }.count == 2)
    }

    /// `submit: true` chains a `pressKeys("Enter")` call after typing completes —
    /// the Enter key ride as its own CDP dispatch on top of the typed characters.
    @Test func submitTrueChainsEnterAfterTyping() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tool = PageTypeExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["aloha_id": .string("q"), "text": .string("a"), "submit": .bool(true)]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("Enter"))
        let enterDown = fixture.cdp.commands(for: "Input.dispatchKeyEvent").first {
            $0.params["key"]?.stringValue == "Enter"
        }
        #expect(enterDown != nil)
    }

    /// `replace` defaults to `true` when omitted — preserved exactly from
    /// `PageBridge.swift`'s `type` case (an append default previously doubled a
    /// re-typed field: "login username -> loop"). Proven end-to-end: with no
    /// `replace` argument at all, the field is still cleared (a select-all
    /// evaluate) before typing begins.
    @Test func replaceOmittedStillClearsFirst() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tool = PageTypeExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["aloha_id": .string("field-1"), "text": .string("x")]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        let evaluated = fixture.cdp.commands(for: "Runtime.evaluate")
            .compactMap { $0.params["expression"]?.stringValue }
        #expect(evaluated.contains { $0.contains("getSelection") || $0.contains(".select()") })
    }

    @Test func batchSubmitReportsTheSettledURL() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.bodyText = "https://example.com/submitted?name=F1"
        let tool = PageTypeExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object([
                "fields": .array([.object(["aloha_id": .string("q"), "text": .string("F1")])]),
                "submit": .bool(true)
            ]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true, "\(result.output)")
        #expect(result.output.contains("Navigated to https://example.com/submitted?name=F1"), "\(result.output)")
        #expect(!result.output.contains("did NOT navigate"), "\(result.output)")
    }

    @Test func batchStillSaysNothingMovedWhenNothingMoved() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.bodyText = "https://example.com"
        let tool = PageTypeExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object([
                "fields": .array([.object(["aloha_id": .string("q"), "text": .string("F1")])]),
                "submit": .bool(true)
            ]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true, "\(result.output)")
        #expect(result.output.contains("did NOT navigate"), "\(result.output)")
    }

    @Test func batchWithoutSubmitReportsTheSettledURL() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.bodyText = "https://example.com/step2"
        let tool = PageTypeExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(
            .object(["fields": .array([.object(["aloha_id": .string("q"), "text": .string("F1")])])]),
            makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true, "\(result.output)")
        #expect(result.output.contains("Navigated to https://example.com/step2"), "\(result.output)")
    }
}
