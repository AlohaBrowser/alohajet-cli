import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// The close guard is the one security control in `manage_tabs`, and the version it
// replaced was dead for the whole life of the file: it tested `isPinned`, which every
// CDP-backed tab hardcodes to `false`. A guard nothing exercises is how that happens
// twice, so this is the check that fails if it stops firing.

@MainActor private final class FakeTab: TabHandle {
    let id: String
    var title: String?
    var url: String
    let attribution: TabAttribution
    var tabType = "website"
    var faviconUrl: String?
    var agentDOM: AgentDOMSnapshotting? { nil }

    init(id: String, url: String, owner: TabOwner) {
        self.id = id
        self.url = url
        self.attribution = TabAttribution(owner: owner)
        self.title = id
    }

    func wake(_ signal: AbortSignal?) async throws -> WakeResult { WakeResult(ok: true) }
    func viewportBounds() -> TabViewportBounds? { nil }
    func startNetworkRecording(logPath: String) {}
}

@MainActor private final class FakeTabs: TabsModel {
    var handles: [FakeTab]
    var activeTabId: String?
    private(set) var closed: [String] = []

    init(_ handles: [FakeTab]) { self.handles = handles }

    func setActiveTabId(_ id: String?) { activeTabId = id }
    var tabsById: [String: TabHandle] { Dictionary(uniqueKeysWithValues: handles.map { ($0.id, $0) }) }
    var orderedTabs: [TabHandle] { handles }
    func tab(_ id: String) -> TabHandle? { handles.first { $0.id == id } }
    func createTab(_ spec: TabCreateSpec) -> TabHandle {
        let handle = FakeTab(id: "new", url: spec.url, owner: spec.owner)
        handles.append(handle)
        return handle
    }
    func closeTab(_ id: String, skipConfirm: Bool) async {
        closed.append(id)
        handles.removeAll { $0.id == id }
    }
    func getTabContext(windowId: String, tab: TabHandle, signal: AbortSignal?) async throws -> TabReadContext? { nil }
}

@MainActor private final class FakeWindow: TabsWindow {
    let id = "window"
    let model: FakeTabs
    var tabs: TabsModel { model }
    init(_ model: FakeTabs) { self.model = model }
}

@MainActor private final class FakeSession: ChatModeSession {
    var active: String?
    func sessionNetworkDir() -> String? { nil }
    func registerNetworkRecordingTab(_ tab: TabHandle) {}
    func unregisterNetworkRecordingTab(_ tabId: String) {}
    func setActiveBrowserTab(_ tabId: String?) { active = tabId }
    func getActiveBrowserTabId() -> String? { active }
    func clearActiveBrowserTabIfMatches(_ tabId: String) { if active == tabId { active = nil } }
}

@MainActor private func fixture() -> (FakeTabs, FakeWindow, ManageTabsActionContext) {
    let model = FakeTabs([
        FakeTab(id: "users-tab", url: "https://example.com/", owner: .user),
        FakeTab(id: "agents-tab", url: "https://example.org/", owner: .chat("s"))
    ])
    return (model, FakeWindow(model),
            ManageTabsActionContext(sessionId: "s", toolCallId: "c", session: FakeSession(), abortSignal: nil))
}

@Test @MainActor func closeRefusesATabTheUserOpened() async {
    let (model, window, ctx) = fixture()
    let result = await manageTabsClose("users-tab", window, ctx)
    #expect(result.isError)
    #expect(result.output?.contains("it is the user's tab, not yours") == true)
    #expect(model.closed.isEmpty)
    #expect(model.tab("users-tab") != nil)
}

@Test @MainActor func closeAllowsATabTheAgentOpened() async {
    let (model, window, ctx) = fixture()
    let result = await manageTabsClose("agents-tab", window, ctx)
    #expect(!result.isError)
    #expect(model.closed == ["agents-tab"])
}

@Test @MainActor func listMarksTheTabThePageToolsAddress() {
    let (_, window, ctx) = fixture()
    ctx.session.setActiveBrowserTab("agents-tab")
    let output = manageTabsList(window, ctx.session, askingChat: ctx.sessionId).output ?? ""
    #expect(output.contains("(tab-id: agents-tab) — your tab, in use"))
    #expect(output.components(separatedBy: "in use").count == 2)
}

@Test @MainActor func listMarksNothingWhenNoTabIsInUse() {
    let (_, window, ctx) = fixture()
    let output = manageTabsList(window, ctx.session, askingChat: ctx.sessionId).output ?? ""
    #expect(!output.contains("in use"))
}

@Test @MainActor func listNamesWhichTabsAreTheUsers() {
    let (_, window, ctx) = fixture()
    let output = manageTabsList(window, nil, askingChat: ctx.sessionId).output ?? ""
    #expect(output.contains("(tab-id: users-tab) — the user's tab"))
    // Exactly one of the two tabs carries it.
    #expect(output.components(separatedBy: "the user's tab").count == 2)
}
