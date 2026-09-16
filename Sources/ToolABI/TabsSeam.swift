import Foundation


// MARK: - Tabs service seam

/// The window a tabs action operates against. The model surface is intentionally
/// kept minimal for now and is extended as the individual tab actions are filled in.
public protocol TabsWindow: AnyObject {
    /// The window identity (read when fetching the legacy tab context).
    var id: String { get }
    var tabs: TabsModel { get }
}

public protocol TabsModel: AnyObject {
    var activeTabId: String? { get }
    func setActiveTabId(_ id: String?)
    var tabsById: [String: TabHandle] { get }
    /// The insertion-ordered tab handles (used by list + same-URL reuse).
    var orderedTabs: [TabHandle] { get }
    func getOrRestoreTab(_ id: String, restoreIfNeeded: Bool) -> TabHandle?
    func tab(_ id: String) -> TabHandle?
    func createTab(_ spec: TabCreateSpec) -> TabHandle
    func closeTab(_ id: String, skipConfirm: Bool) async
    /// Reads the legacy/non-interactive tab context.
    func getTabContext(windowId: String, tab: TabHandle, signal: AbortSignal?) async throws -> TabReadContext?
}

// MARK: - Click-spawned tab adoption seam

/// A tab adopted into the model after a click spawned a new top-level page
/// target (e.g. a `target=_blank` link).
public struct AdoptedTab: Sendable {
    public let id: String
    public let url: String
    public let title: String?
    public init(id: String, url: String, title: String?) {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// An optional capability a ``TabsModel`` opts into to let the click path detect
/// and adopt page targets a click spawned. It is intentionally kept off the base
/// ``TabsModel`` protocol so non-supporting models compile unchanged; the click
/// path probes for it with `model as? ClickSpawnedTabAdopting`.
public protocol ClickSpawnedTabAdopting: AnyObject {
    /// Snapshots the live page target ids before an action, so the post-action
    /// diff can tell a genuinely-new target from one that already existed.
    func currentPageTargetIds() async -> Set<String>
    /// Adopts each live page target not in `previous` (and not already tracked)
    /// as an agent-controlled background tab, returning the adopted tabs. Already
    /// known / previously-seen targets are skipped, so a repeated identical click
    /// adopts nothing.
    func adoptSpawnedTabs(notIn previous: Set<String>) async -> [AdoptedTab]
}

/// Refreshing the cached per-tab metadata (url and title) from the live browser. Kept
/// off ``TabsModel`` and probed with `as?`, like the seams around it: a model with no
/// browser behind it has nothing to refresh from.
public protocol LiveTabMetadataRefreshing: AnyObject {
    /// Re-reads url and title for every tracked tab. One call for the whole window, so a
    /// list or a read pays one round-trip rather than one per tab.
    func refreshTabMetadata() async
}

/// Addressing a live page target the model never saw. Kept off ``TabsModel`` and
/// probed with `as?`, like the seam above.
public protocol LivePageTargetAdopting: AnyObject {
    /// The handle for `id`, registering it when the browser still reports it as a
    /// live `page` target; `nil` otherwise — including for a tab this model closed.
    func adoptLiveTarget(_ id: String) async -> TabHandle?
}

/// Clearing whatever blocked a page read — a CAPTCHA a host can solve — once the read
/// has already happened. Kept off ``TabHandle`` and probed with `as?`, like the seams
/// above: a handle with no remediation behind it conforms to nothing and the read path
/// stays exactly one read.
///
/// It cannot live INSIDE the read: a successful remediation must be followed by a fresh
/// read, and a read that starts a read recurses. So the read path calls it between its
/// two reads, and `signal` is the calling tool's own cancellation token — remediation
/// spends real time and a user pressing Stop has to unwind it.
public protocol PageReadRemediating: AnyObject {
    /// Runs at most one remediation attempt against the page just read. `true` when the
    /// caller should read again (the page changed); `false` when nothing on the page
    /// qualified, or this document already had its one attempt.
    func remediateAfterRead(_ signal: AbortSignal?) async -> Bool
}

public protocol TabHandle: AgentControllableTab {
    var id: String { get }
    var title: String? { get }
    var url: String { get }
    /// Whether this tab belongs to the user rather than the agent: it was already
    /// open when the session attached, or restored/adopted as a live browser
    /// target. `false` only for tabs this session opened itself. `manage_tabs
    /// close` refuses a tab whose value is `true`.
    ///
    /// This replaced an `isPinned` flag: pinning is a browser-UI concept the
    /// DevTools protocol does not expose (`Target.TargetInfo` has no such field),
    /// so every CDP-backed tab reported `false` and the close guard that tested it
    /// never fired once.
    var openedByHuman: Bool { get }
    var tabType: String { get }
    var faviconUrl: String? { get }
    var userTookOver: Bool { get }
    var agentDOM: AgentDOMSnapshotting? { get }
    /// Wakes the tab: ensures a website tab is loaded with live web contents
    /// before snapshotting; non-website tabs are always ready.
    func wake(_ signal: AbortSignal?) async throws -> WakeResult
    /// Probes the layer bounds for the `Viewport: WxH` line; `nil` when no
    /// live/positive-size layer.
    func viewportBounds() -> TabViewportBounds?
    /// Begins JSONL network recording for a freshly-opened agent tab.
    func startNetworkRecording(logPath: String)
}

/// The probed viewport bounds of a tab's live layer.
public nonisolated struct TabViewportBounds: Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public nonisolated struct TabCreateSpec: Sendable {
    public var tabType: String
    public var url: String
    public var openedByHuman: Bool
    public var agentControllerId: String?
    public var sessionId: String?
    public init(tabType: String, url: String, openedByHuman: Bool, agentControllerId: String? = nil, sessionId: String? = nil) {
        self.tabType = tabType
        self.url = url
        self.openedByHuman = openedByHuman
        self.agentControllerId = agentControllerId
        self.sessionId = sessionId
    }
}

/// The legacy/non-interactive tab read context.
public nonisolated struct TabReadContext: Sendable {
    public var data: String?
    public var type: String
    public var domainSpecificData: [String]?
    public init(
        data: String?,
        type: String,
        domainSpecificData: [String]? = nil
    ) {
        self.data = data
        self.type = type
        self.domainSpecificData = domainSpecificData
    }
}

/// The tabs service the agent's browser tools resolve their window from. The
/// concrete window is provided by the app shell; tools read
/// `services.tabsService?.window`.
public protocol TabsService: AnyObject {
    var window: TabsWindow? { get }
}

// MARK: - Browser tool services

/// The bundle of services a browser tool reads from its execution context. Both
/// service handles are optional, so a context can be built with nothing wired.
///
/// Holds reference-typed service handles and is main-actor isolated, like the
/// execution context it is threaded through.
///
/// `open` rather than `final`: a host whose own bundle carries dozens of service
/// handles subclasses this instead of either side widening — these three are the
/// only ones the tools in this package read.
open class NativeToolServices {
    public let tabsService: TabsService?
    public let session: ChatModeSession?
    /// The toggleable web-extraction options read by the `manage_tabs` read path.
    public let webExtractionOptions: AgentWebExtractionOptions

    public init(
        tabsService: TabsService? = nil,
        session: ChatModeSession? = nil,
        webExtractionOptions: AgentWebExtractionOptions = .baseline
    ) {
        self.tabsService = tabsService
        self.session = session
        self.webExtractionOptions = webExtractionOptions
    }
}
