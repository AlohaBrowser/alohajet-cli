import Foundation
import Testing
import ToolABI
import CDP
@testable import BrowserTools

// MARK: - In-memory tabs doubles (shared across the 7 atomic page-tool test files)
//
// Mirrors `TabExecuteActiveTabResolutionTests.swift`'s file-scope doubles, but
// declared `internal` (not `private`) so every `page_*` / `get_text` test file
// in this target can reuse ONE copy instead of seven near-duplicates. The stub
// tab is `tabType: "website"` but is NOT a `CDPTabHandle`, so it exercises the
// "not an interactive website tab" resolution branch — the one negative path
// every one of the seven tools shares (`resolveActivePageTab` in
// `PageToolsSupport.swift`) without needing a live CDP connection.

final class PageToolsStubTabHandle: TabHandle {
    let id: String
    var title: String?
    var url: String
    var openedByHuman: Bool
    var tabType: String
    var faviconUrl: String?
    var userTookOver: Bool

    private var _chatSessionId: String?
    private var _aiControlled = false
    private var _browserControlled = false
    private var _agentId: String?

    init(id: String, url: String, title: String? = nil, tabType: String = "website", openedByHuman: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.tabType = tabType
        self.openedByHuman = openedByHuman
        self.faviconUrl = nil
        self.userTookOver = false
    }

    var agentDOM: AgentDOMSnapshotting? { nil }
    private(set) var wakeCalls = 0
    var wakeResult = WakeResult(ok: true)
    func wake(_ signal: AbortSignal?) async throws -> WakeResult {
        wakeCalls += 1
        return wakeResult
    }
    func viewportBounds() -> TabViewportBounds? { nil }
    func startNetworkRecording(logPath: String) {}

    var browserAgentControlledAgentId: String? { _agentId }
    var chatSessionId: String? {
        get { _chatSessionId }
        set { _chatSessionId = newValue }
    }
    var isAIControlledTab: Bool { _aiControlled }
    var isBrowserAgentControlled: Bool { _browserControlled }
    func setAIControlledTab(_ controlled: Bool, agentId: String?) {
        _aiControlled = controlled
        _browserControlled = !controlled
        _agentId = agentId
    }
}

final class PageToolsStubTabsModel: TabsModel, LivePageTargetAdopting {
    private var handles: [String: PageToolsStubTabHandle]
    private var order: [String]
    private var _activeTabId: String?

    /// Ids this fake browser reports as live `page` targets the model has never
    /// seen, and how many times the adoption seam was actually reached.
    var liveTargets: Set<String> = []
    private(set) var adoptCallCount = 0

    init(_ tabs: [PageToolsStubTabHandle], activeTabId: String? = nil, liveTargets: Set<String> = []) {
        self.handles = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        self.order = tabs.map { $0.id }
        self._activeTabId = activeTabId
        self.liveTargets = liveTargets
    }

    func adoptLiveTarget(_ id: String) async -> TabHandle? {
        adoptCallCount += 1
        guard liveTargets.contains(id) else { return nil }
        let handle = PageToolsStubTabHandle(id: id, url: "https://live.example/\(id)")
        handles[id] = handle
        order.append(id)
        return handle
    }

    var activeTabId: String? { _activeTabId }
    func setActiveTabId(_ id: String?) { _activeTabId = id }
    var tabsById: [String: TabHandle] { handles }
    var orderedTabs: [TabHandle] { order.compactMap { handles[$0] } }
    func getOrRestoreTab(_ id: String, restoreIfNeeded: Bool) -> TabHandle? { handles[id] }
    func tab(_ id: String) -> TabHandle? { handles[id] }

    func createTab(_ spec: TabCreateSpec) -> TabHandle {
        let handle = PageToolsStubTabHandle(
            id: "stub-\(handles.count)", url: spec.url, tabType: spec.tabType,
            openedByHuman: spec.openedByHuman)
        handles[handle.id] = handle
        order.append(handle.id)
        return handle
    }

    func closeTab(_ id: String, skipConfirm: Bool) async {
        handles.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if _activeTabId == id { _activeTabId = nil }
    }

    func getTabContext(windowId: String, tab: TabHandle, signal: AbortSignal?) async throws -> TabReadContext? { nil }
}

final class PageToolsStubTabsWindow: TabsWindow {
    let id = "stub-window"
    let model: PageToolsStubTabsModel
    init(_ model: PageToolsStubTabsModel) { self.model = model }
    var tabs: TabsModel { model }
}

final class PageToolsStubTabsService: TabsService {
    let stubWindow: PageToolsStubTabsWindow?
    init(_ window: PageToolsStubTabsWindow?) { self.stubWindow = window }
    var window: TabsWindow? { stubWindow }
}

// MARK: - Recording AgentBridgeBackend (driver-level tests)
//
// One scripted `AgentBridgeBackend` for the whole test target, declared internal
// so the `AgentBrowserBridge` driver methods (`selectOptionById` / `getTextById` /
// `waitForSelector`) can be tested without duplicating the stub per-file. Each queues one scripted `evaluateViaCdp` reply per call (FIFO);
// when the queue is empty the last-set `evaluateResult` is repeated — enough to
// answer BOTH the idempotent runtime-install call (result discarded by the
// caller) and the real verb call with a single assignment when the install
// call's return value does not matter, or to script the two independently via
// `evaluateResultQueue`.

@MainActor
final class PageToolsRecordingBackend: AgentBridgeBackend {
    var aborted = false
    var evaluateResult: JSValue?
    var evaluateResultQueue: [JSValue?] = []
    var evaluateError: Error?
    private(set) var capturedScripts: [String] = []

    var isAborted: Bool { aborted }
    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        capturedScripts.append(expression)
        if let evaluateError { throw evaluateError }
        if !evaluateResultQueue.isEmpty { return evaluateResultQueue.removeFirst() }
        return evaluateResult
    }
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue { .null }
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? { nil }
    func viewportDimensions() -> ViewportSize? { nil }
    func resolveSandboxSavePath(_ path: String) -> String? { nil }
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}

    /// Every captured `evaluateViaCdp` expression after the first (the
    /// idempotent runtime-install call every driver method issues first).
    var scriptsAfterRuntimeInstall: [String] { Array(capturedScripts.dropFirst()) }
}

// MARK: - Minimal ToolExecutionContext construction
//
// No existing test in this target constructs a `ToolExecutionContext` directly
// (production code is the sole caller); these tools are the first to need one,
// so this minimal no-op `ExecutorSession` + a small factory function are new,
// shared here for all 7 test files.

final class PageToolsNoopExecutorSession: ExecutorSession {
    func findToolResult(_ toolCallId: String) -> ToolResultBlockView? { nil }
    func updateToolCallResult(_ toolCallId: String, _ update: ToolResultUpdate) {}
    func emitMessagesUpdated(_ messageId: String?) {}
    func createToolMessageGroup(_ call: ToolCall, output: String, status: ToolResultStatus, metadata: ToolMetadata?, toolType: String) async -> String { "" }
    var agents: [String: AgentRecord] { [:] }
    func detachAgent(_ agentId: String) {}
    func save() {}
}

/// Builds a minimal `ToolExecutionContext` wired to `services`, with a fresh,
/// never-aborted signal and every other collaborator a harmless no-op — enough
/// for a `page_*` / `get_text` executor tool's `execute(_:_:)` to run to
/// completion.
@MainActor
func makePageToolContext(services: NativeToolServices?, signal: AbortSignal = AbortSignal()) -> ToolExecutionContext {
    ToolExecutionContext(
        sessionId: "test-session",
        toolCallId: "call-1",
        signal: signal,
        mode: .foreground,
        turnId: nil,
        session: PageToolsNoopExecutorSession(),
        isBackground: { false },
        getSandbox: { nil },
        env: [:],
        services: services,
        suspend: { _ in nil }
    )
}

// MARK: - Real CDPTabHandle fixture (MockCDP-backed, no real Chrome)
//
// For the one true happy-path test per tool: builds a real `CDPTabHandle`
// behind a `CDPClient` connected to a scripted `MockCDP`, exactly like
// `ManageTabsActionsE2ETests.swift`'s fixture, but WITHOUT the full
// `BrowserAgent`/LLM turn loop — these tools are driven directly via
// `execute(_:_:)`, so only the tabs-service half of that fixture is needed.

struct PageToolsCDPFixture {
    let cdp: MockCDP
    let client: CDPClient
    let tabsService: TabsService
    let tabId: String
}

/// Connects a `CDPClient` to a fresh `MockCDP`, seeds one active `website` tab,
/// and wraps it in `NativeToolServices` — the fixture every `page_*` / `get_text`
/// happy-path test starts from.
@MainActor
func makePageToolsCDPFixture(url: String = "https://example.com") async throws -> PageToolsCDPFixture {
    let cdp = MockCDP()
    let channel = cdp.channel()
    let client = CDPClient(channel: channel)
    try await client.connect()
    let tabsService = await makeCDPBrowserTabsService(client: client, seed: false)
    let tabs = try #require(tabsService.window).tabs
    let tab = tabs.createTab(TabCreateSpec(tabType: "website", url: url, openedByHuman: false))
    tabs.setActiveTabId(tab.id)
    return PageToolsCDPFixture(cdp: cdp, client: client, tabsService: tabsService, tabId: tab.id)
}
