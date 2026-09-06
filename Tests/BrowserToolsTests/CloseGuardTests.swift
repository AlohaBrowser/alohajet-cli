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
    let openedByHuman: Bool
    var tabType = "website"
    var faviconUrl: String?
    var userTookOver = false
    var agentDOM: AgentDOMSnapshotting? { nil }
    var browserAgentControlledAgentId: String?
    var chatSessionId: String?
    var isAIControlledTab = false
    var isBrowserAgentControlled = false

    init(id: String, url: String, openedByHuman: Bool) {
        self.id = id
        self.url = url
        self.openedByHuman = openedByHuman
        self.title = id
    }

    func setAIControlledTab(_ controlled: Bool, agentId: String?) {
        isAIControlledTab = controlled
        isBrowserAgentControlled = !controlled
        browserAgentControlledAgentId = agentId
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
    func getOrRestoreTab(_ id: String, restoreIfNeeded: Bool) -> TabHandle? { tab(id) }
    func tab(_ id: String) -> TabHandle? { handles.first { $0.id == id } }
    func createTab(_ spec: TabCreateSpec) -> TabHandle {
        let handle = FakeTab(id: "new", url: spec.url, openedByHuman: spec.openedByHuman)
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
        FakeTab(id: "users-tab", url: "https://example.com/", openedByHuman: true),
        FakeTab(id: "agents-tab", url: "https://example.org/", openedByHuman: false)
    ])
    return (model, FakeWindow(model),
            ManageTabsActionContext(sessionId: "s", toolCallId: "c", session: FakeSession(), abortSignal: nil))
}

@Test @MainActor func closeRefusesATabTheUserOpened() async {
    let (model, window, ctx) = fixture()
    let result = await manageTabsClose("users-tab", window, ctx)
    #expect(result.isError)
    #expect(result.output?.contains("the user's tab") == true)
    #expect(model.closed.isEmpty)
    #expect(model.tab("users-tab") != nil)
}

@Test @MainActor func closeAllowsATabTheAgentOpened() async {
    let (model, window, ctx) = fixture()
    let result = await manageTabsClose("agents-tab", window, ctx)
    #expect(!result.isError)
    #expect(model.closed == ["agents-tab"])
}

@Test @MainActor func listNamesWhichTabsAreTheUsers() {
    let (_, window, _) = fixture()
    let output = manageTabsList(window).output ?? ""
    #expect(output.contains("[the user's tab — cannot be closed]"))
    // Exactly one of the two tabs carries it.
    #expect(output.components(separatedBy: "[the user's tab").count == 2)
}
