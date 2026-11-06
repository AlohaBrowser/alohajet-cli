import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// A host's remediation can move the tab to another document between the two reads of
// `readPageBody`: the check page passes and the site it guarded loads. The body is the
// second read, so the row above it has to name that document too — not the check page
// the listing reported before the first read, with its one-time token in the address.

@MainActor private final class BrowserDocument {
    var title: String
    var url: String
    init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

@MainActor private final class DocumentDOM: AgentDOMSnapshotting {
    let document: BrowserDocument
    init(_ document: BrowserDocument) { self.document = document }
    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool) async throws -> ToolABI.InteractMarkdownResult {
        ToolABI.InteractMarkdownResult(markdown: "# \(document.title)", screenshot: nil, diagnostics: .init())
    }
}

@MainActor private final class CheckedTab: TabHandle, PageReadRemediating {
    let id: String
    var title: String?
    var url: String
    let attribution: TabAttribution
    let tabType = "website"
    var faviconUrl: String? { nil }
    let document: BrowserDocument
    let checkPasses: Bool

    init(id: String, url: String, owner: TabOwner, document: BrowserDocument, checkPasses: Bool) {
        self.id = id
        self.url = url
        self.attribution = TabAttribution(owner: owner)
        self.document = document
        self.checkPasses = checkPasses
    }

    var agentDOM: AgentDOMSnapshotting? { DocumentDOM(document) }
    func wake(_ signal: AbortSignal?) async throws -> WakeResult { WakeResult(ok: true) }
    func viewportBounds() -> TabViewportBounds? { nil }
    func startNetworkRecording(logPath: String) {}

    func remediateAfterRead(_ signal: AbortSignal?) async -> Bool {
        guard checkPasses else { return false }
        document.title = "Challenge passed"
        document.url = "https://site.example/protected"
        return true
    }
}

/// The listing copies the browser's title and address onto every handle, as the CDP tabs
/// model does.
@MainActor private final class ListingTabs: TabsModel, BrowserTabSyncing {
    let document: BrowserDocument
    let checkPasses: Bool
    var handles: [CheckedTab] = []
    var activeTabId: String?
    private(set) var syncs = 0

    init(document: BrowserDocument, checkPasses: Bool) {
        self.document = document
        self.checkPasses = checkPasses
    }

    func syncTabsWithBrowser() async {
        syncs += 1
        for handle in handles {
            handle.title = document.title
            handle.url = document.url
        }
    }

    func setActiveTabId(_ id: String?) { activeTabId = id }
    var tabsById: [String: TabHandle] { Dictionary(uniqueKeysWithValues: handles.map { ($0.id, $0) }) }
    var orderedTabs: [TabHandle] { handles }
    func tab(_ id: String) -> TabHandle? { handles.first { $0.id == id } }
    func createTab(_ spec: TabCreateSpec) -> TabHandle {
        let handle = CheckedTab(id: "checked-tab", url: spec.url, owner: spec.owner,
                                document: document, checkPasses: checkPasses)
        handles.append(handle)
        return handle
    }
    func closeTab(_ id: String, skipConfirm: Bool) async {}
    func getTabContext(windowId: String, tab: TabHandle, signal: AbortSignal?) async throws -> TabReadContext? { nil }
}

@MainActor private final class ListingWindow: TabsWindow {
    let id = "window"
    let model: ListingTabs
    var tabs: TabsModel { model }
    init(_ model: ListingTabs) { self.model = model }
}

@MainActor private final class InUseSession: ChatModeSession {
    var active: String?
    func sessionNetworkDir() -> String? { nil }
    func registerNetworkRecordingTab(_ tab: TabHandle) {}
    func unregisterNetworkRecordingTab(_ tabId: String) {}
    func setActiveBrowserTab(_ tabId: String?) { active = tabId }
    func getActiveBrowserTabId() -> String? { active }
    func clearActiveBrowserTabIfMatches(_ tabId: String) { if active == tabId { active = nil } }
}

private let checkTitle = "Checking your browser"
private let checkURL = "https://site.example/protected?challenge_token=x"

@MainActor private func checkedBrowser(checkPasses: Bool) -> (ListingTabs, ListingWindow, ManageTabsActionContext) {
    let model = ListingTabs(document: BrowserDocument(title: checkTitle, url: checkURL), checkPasses: checkPasses)
    return (model, ListingWindow(model),
            ManageTabsActionContext(sessionId: "s", toolCallId: "c", session: InUseSession(), abortSignal: nil))
}

@Suite("a remediated read's row names the document it read")
@MainActor struct RemediatedReadRowTests {

    @Test func openNamesThePageTheCheckLeftNotTheCheck() async {
        let (_, window, ctx) = checkedBrowser(checkPasses: true)

        let result = await manageTabsOpen("https://site.example/protected", window, ctx, true, "agent", false)
        let output = result.output ?? ""

        #expect(!result.isError, "\(output)")
        #expect(output.components(separatedBy: "\n").first
            == "Opened: Challenge passed [https://site.example/protected] (tab-id: checked-tab) — your tab, in use")
        #expect(!output.contains(checkTitle), "\(output)")
        #expect(!output.contains("challenge_token"), "\(output)")
    }

    @Test func readNamesThePageTheCheckLeftAndReturnsItsAddress() async {
        let (model, window, ctx) = checkedBrowser(checkPasses: true)
        let tab = model.createTab(TabCreateSpec(tabType: "website", url: checkURL, owner: .chat("s")))
        ctx.session.setActiveBrowserTab(tab.id)

        let result = await manageTabsRead(tab.id, window, ctx, false)
        let output = result.output ?? ""

        #expect(!result.isError, "\(output)")
        #expect(output.components(separatedBy: "\n").first
            == "Challenge passed [https://site.example/protected] (tab-id: checked-tab) — your tab, in use")
        #expect(result.url == "https://site.example/protected")
        #expect(!output.contains("challenge_token"), "\(output)")
    }

    @Test func aCheckThatStaysKeepsItsRowAndListsOnce() async {
        let (model, window, ctx) = checkedBrowser(checkPasses: false)

        let result = await manageTabsOpen("https://site.example/protected", window, ctx, true, "agent", false)

        #expect(result.output?.components(separatedBy: "\n").first
            == "Opened: \(checkTitle) [\(checkURL)] (tab-id: checked-tab) — your tab, in use")
        #expect(model.syncs == 1)
    }
}
