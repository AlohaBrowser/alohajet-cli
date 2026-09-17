import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// The `manage_tabs` WIRE: the names and values a caller sends, as opposed to what the actions do
// once the call is parsed. Three things are pinned here, and each one is invisible to every other
// test in this target: the un-advertised legacy spellings still being accepted, `controlled_by`
// opening a tab the agent does not own, and `canonicalToolWireSurface` being the whole roster.
//
// `.serialized` because `manageTabsLegacyWireHits` is one process-global counter and these tests
// assert deltas on it.

@MainActor private final class WireSession: ChatModeSession {
    var active: String?
    func sessionNetworkDir() -> String? { nil }
    func registerNetworkRecordingTab(_ tab: TabHandle) {}
    func unregisterNetworkRecordingTab(_ tabId: String) {}
    func setActiveBrowserTab(_ tabId: String?) { active = tabId }
    func getActiveBrowserTabId() -> String? { active }
    func clearActiveBrowserTabIfMatches(_ tabId: String) { if active == tabId { active = nil } }
}

@MainActor private func wireFixture(
    _ tabs: [PageToolsStubTabHandle] = []
) -> (PageToolsStubTabsModel, WireSession, ToolExecutionContext) {
    let model = PageToolsStubTabsModel(tabs)
    let session = WireSession()
    let services = NativeToolServices(
        tabsService: PageToolsStubTabsService(PageToolsStubTabsWindow(model)), session: session)
    return (model, session, makePageToolContext(services: services))
}

@MainActor private func call(_ arguments: [String: WorkflowValue], _ context: ToolExecutionContext) async throws -> RawToolResult {
    try await ManageTabsExecutorTool().execute(.object(arguments), context)
}

@Suite("manage_tabs wire", .serialized) @MainActor struct ManageTabsWireTests {
    // MARK: The one-release synonym shim

    @Test func focusAndTabIdAreStillAccepted() async throws {
        let (_, session, context) = wireFixture([PageToolsStubTabHandle(id: "t1", url: "https://example.com/")])
        let before = manageTabsLegacyWireHits

        let result = try await call(["action": .string("focus"), "tabId": .string("t1")], context)

        #expect(result.isError != true)
        #expect(session.active == "t1")
        #expect(manageTabsLegacyWireHits["focus", default: 0] == before["focus", default: 0] + 1)
        #expect(manageTabsLegacyWireHits["tabId", default: 0] == before["tabId", default: 0] + 1)
    }

    @Test func unfocusIsStillAccepted() async throws {
        let (_, session, context) = wireFixture([PageToolsStubTabHandle(id: "t1", url: "https://example.com/")])
        session.active = "t1"
        let before = manageTabsLegacyWireHits

        let result = try await call(["action": .string("unfocus")], context)

        #expect(result.output.contains("No tab is in use now (was \"t1\")"))
        #expect(session.active == nil)
        #expect(manageTabsLegacyWireHits["unfocus", default: 0] == before["unfocus", default: 0] + 1)
    }

    /// The canonical spelling must not be counted, or the counter can never reach zero and the
    /// shim can never be retired.
    @Test func theCanonicalSpellingIsNotCounted() async throws {
        let (_, session, context) = wireFixture([PageToolsStubTabHandle(id: "t1", url: "https://example.com/")])
        let before = manageTabsLegacyWireHits

        _ = try await call(["action": .string("use"), "tab_id": .string("t1")], context)

        #expect(session.active == "t1")
        #expect(manageTabsLegacyWireHits == before)
    }

    /// Both spellings in one call: the advertised one wins, and nothing is counted twice.
    @Test func tabIdLosesToTabIdUnderscore() async throws {
        let (_, session, context) = wireFixture([
            PageToolsStubTabHandle(id: "t1", url: "https://example.com/"),
            PageToolsStubTabHandle(id: "t2", url: "https://example.org/")
        ])
        let before = manageTabsLegacyWireHits

        _ = try await call(
            ["action": .string("use"), "tab_id": .string("t1"), "tabId": .string("t2")], context)

        #expect(session.active == "t1")
        #expect(manageTabsLegacyWireHits == before)
    }

    /// `open` used to spell its background flag `focus: false`. A replayed call carrying it
    /// must still leave the tab in use alone, or the page tools silently change target.
    @Test func openStillHonorsTheLegacyFocusFalse() async throws {
        let (model, session, context) = wireFixture()
        let before = manageTabsLegacyWireHits

        _ = try await call([
            "action": .string("open"), "url": .string("https://example.com/"), "focus": .bool(false)
        ], context)

        let opened = try #require(model.orderedTabs.last)
        #expect(!opened.openedByHuman)
        #expect(session.active == nil)
        #expect(manageTabsLegacyWireHits["focus", default: 0] == before["focus", default: 0] + 1)
    }

    // MARK: controlled_by

    @Test func openControlledByUserOpensATabTheAgentDoesNotOwn() async throws {
        let (model, session, context) = wireFixture()

        let result = try await call([
            "action": .string("open"), "url": .string("https://example.com/"),
            "controlled_by": .string("user")
        ], context)

        let opened = try #require(model.orderedTabs.last)
        #expect(opened.openedByHuman)
        #expect(opened.browserAgentControlledAgentId == nil)
        // Never taken into use, even though `use` defaults to true.
        #expect(session.active == nil)
        #expect(result.output.contains("This tab is the user's"))
    }

    @Test func aUserControlledTabCannotBeClosedAgain() async throws {
        let (model, _, context) = wireFixture()

        _ = try await call([
            "action": .string("open"), "url": .string("https://example.com/"),
            "controlled_by": .string("user")
        ], context)
        let openedId = try #require(model.orderedTabs.last).id
        let closed = try await call(["action": .string("close"), "tab_id": .string(openedId)], context)

        #expect(closed.isError == true)
        #expect(closed.output.contains("the user's tab"))
        #expect(model.tab(openedId) != nil)
    }

    @Test func openDefaultsToAnAgentTab() async throws {
        let (model, session, context) = wireFixture()

        _ = try await call(["action": .string("open"), "url": .string("https://example.com/")], context)

        let opened = try #require(model.orderedTabs.last)
        #expect(!opened.openedByHuman)
        #expect(session.active == opened.id)
    }

    // MARK: canonicalToolWireSurface

    @Test func theSurfaceCoversTheWholeRoster() {
        #expect(Set(canonicalToolWireSurface.keys) == Set(nativeAgentToolNames))
        for name in nativeAgentToolNames {
            #expect(canonicalToolWireSurface[name]?.isEmpty == false, "\(name) has no parameters")
        }
    }

    @Test func theSurfaceIsTheAdvertisedNamesAndEnums() {
        #expect(canonicalToolWireSurface["manage_tabs"] == [
            "action": ["list", "read", "open", "close", "use", "unuse"],
            "tab_id": [],
            "url": [],
            "use": [],
            "controlled_by": ["agent", "user"],
            "include_screenshot": []
        ])
        #expect(canonicalToolWireSurface["page_navigate"] == ["action": ["goto", "back"], "url": []])
        #expect(canonicalToolWireSurface["page_upload"] == ["aloha_id": [], "paths": []])
    }

    /// The shim is compatibility, not API: advertising it would teach new callers the spelling
    /// this package is trying to retire.
    @Test func theSurfaceOmitsTheLegacySynonyms() {
        let manageTabs = canonicalToolWireSurface["manage_tabs"]
        #expect(manageTabs?["tabId"] == nil)
        #expect(manageTabs?["action"]?.contains("focus") == false)
        #expect(manageTabs?["action"]?.contains("unfocus") == false)
    }
}
