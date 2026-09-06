import Testing
import Foundation
import ToolABI
@testable import BrowserTools

@Suite("page_press_keys executor")
@MainActor
struct PagePressKeysExecutorToolTests {
    @Test func requiresKeys() async throws {
        let tool = PagePressKeysExecutorTool()
        let result = try await tool.execute(.object([:]), makePageToolContext(services: nil))
        #expect(result.isError == true)
        #expect(result.output.contains("keys"))
    }

    /// Negative/edge case: an empty `keys` string is rejected the same as
    /// absent, before any tab resolution.
    @Test func emptyKeysIsRejected() async throws {
        let tool = PagePressKeysExecutorTool()
        let result = try await tool.execute(.object(["keys": .string("")]), makePageToolContext(services: nil))
        #expect(result.isError == true)
    }

    @Test func nonInteractiveTabIsRejected() async throws {
        let tool = PagePressKeysExecutorTool()
        let stubTab = PageToolsStubTabHandle(id: "t1", url: "https://a.example")
        let window = PageToolsStubTabsWindow(PageToolsStubTabsModel([stubTab], activeTabId: "t1"))
        let services = NativeToolServices(tabsService: PageToolsStubTabsService(window))
        let result = try await tool.execute(.object(["keys": .string("Enter")]), makePageToolContext(services: services))
        #expect(result.isError == true)
        #expect(result.output.contains("not an interactive website tab"))
    }

    /// Happy path: sends "Enter" and rides real CDP `Input.dispatchKeyEvent`
    /// commands — global and focus-relative, no `aloha_id` involved.
    @Test func enterHappyPathDispatchesRealKeyEvents() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tool = PagePressKeysExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object(["keys": .string("Enter")]), makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        #expect(result.output.contains("Enter"))
        let enterEvents = fixture.cdp.commands(for: "Input.dispatchKeyEvent").filter {
            $0.params["key"]?.stringValue == "Enter"
        }
        #expect(!enterEvents.isEmpty)
        #expect(enterEvents.contains { $0.params["windowsVirtualKeyCode"]?.intValue == 13 })
    }

    /// Happy path (chord): a modifier chord holds and releases the modifier
    /// around the main key.
    @Test func chordHappyPathHoldsModifier() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tool = PagePressKeysExecutorTool()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await tool.execute(.object(["keys": .string("Control+a")]), makePageToolContext(services: services))
        await fixture.client.close()

        #expect(result.isError != true)
        let keys = fixture.cdp.commands(for: "Input.dispatchKeyEvent")
        #expect(keys.contains { $0.params["type"]?.stringValue == "rawKeyDown" && $0.params["key"]?.stringValue == "Control" })
        #expect(keys.contains { $0.params["type"]?.stringValue == "keyUp" && $0.params["key"]?.stringValue == "Control" })
    }
}
