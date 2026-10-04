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

/// Remembering what a tab was ASKED to open, which is not where it ends up. Kept off
/// ``TabHandle`` and probed with `as?`, like the seams above: a handle nobody opened through
/// `manage_tabs open` has nothing to remember.
///
/// `manage_tabs open` reuses a tab of this session that already shows the requested page, and
/// it compares the request against the tab's CURRENT url. That misses whenever the server moved
/// the tab after it opened: measured over 260 opens on one run, 12% landed on a path differing
/// only in CASE (`/submit/earthporn` -> `/submit/EarthPorn`), and once the trailing-slash case
/// was folded, that became the dominant cause of duplicate tabs — the same page re-opened 12 and
/// 9 times in one run. Case cannot be folded safely, because paths are case-sensitive by spec and
/// a server where those are two pages is legal. Remembering the request removes the guess: a
/// later ask for `/submit/earthporn` matches the tab that was OPENED for `/submit/earthporn`,
/// exactly, whatever the server did to it afterwards.
///
/// On the handle rather than in a registry keyed by tab id, so the record lives and dies with
/// the tab and two models in one process cannot see each other's entries.
public protocol OpenRequestRemembering: AnyObject {
    /// The URL `manage_tabs open` created this tab for; `nil` for a tab that was not.
    var requestedOpenURL: String? { get set }
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

// MARK: - Tab housekeeping policy

/// What `manage_tabs` does to the agent's OWN tabs beyond what it was asked, and what a turn
/// may do to them when it ends. Every switch is OFF by default.
///
/// These are behaviours for a setting where the page the agent ENDS ON is what gets graded —
/// the WebArena-style benches read `final_url` from an arbitrary CDP context, so each tab left
/// standing is another way to be scored on a page the agent abandoned, and closing the tab the
/// work is on throws the work away. An ordinary user's session has no such grader: a tab closed
/// under the user is a tab lost, and a refusal to close one is a tool that does not do what it
/// was told. So nothing here runs unless the host turns it on; the batch harness does.
public nonisolated struct TabHousekeepingPolicy: Sendable, Equatable {
    /// How many agent tabs this session may keep open at once; `open` closes the OLDEST
    /// beyond it, never the active tab or the one just opened. `nil` means no cap.
    public var maxAgentTabs: Int?
    /// `close` refuses the most specific page this session has reached, and its last tab.
    public var refuseClosingWorkPage: Bool
    /// The caller may collapse this session's tabs to the one worth keeping when a turn ends
    /// (`collapseAgentTabsAtTurnEnd`); the trigger itself lives in the host's turn runner.
    public var collapseAtTurnEnd: Bool

    public init(maxAgentTabs: Int? = nil, refuseClosingWorkPage: Bool = false, collapseAtTurnEnd: Bool = false) {
        self.maxAgentTabs = maxAgentTabs
        self.refuseClosingWorkPage = refuseClosingWorkPage
        self.collapseAtTurnEnd = collapseAtTurnEnd
    }

    /// Nothing on: the default, and the right setting for a user's browser.
    public static let off = TabHousekeepingPolicy()

    /// Every switch on, with the cap measured for the final-URL benches: THREE, because a task
    /// can legitimately need two pages at once (a source and a destination) and the cap has to
    /// leave room for that working set plus one. Closing below it would trade a grading bug for
    /// a capability loss.
    public static let finalPageGraded = TabHousekeepingPolicy(
        maxAgentTabs: 3, refuseClosingWorkPage: true, collapseAtTurnEnd: true)
}

// MARK: - Browser tool services

/// The bundle of services a browser tool reads from its execution context. Both
/// service handles are optional, so a context can be built with nothing wired.
///
/// Holds reference-typed service handles and is main-actor isolated, like the
/// execution context it is threaded through.
///
/// `open` rather than `final`: a host whose own bundle carries dozens of service
/// handles subclasses this instead of either side widening — these four are the
/// only ones the tools in this package read.
open class NativeToolServices {
    public let tabsService: TabsService?
    public let session: ChatModeSession?
    /// The toggleable web-extraction options read by the `manage_tabs` read path.
    public let webExtractionOptions: AgentWebExtractionOptions
    /// What `manage_tabs` may do to the agent's own tabs unasked. `.off` unless the host
    /// says otherwise — see ``TabHousekeepingPolicy``.
    public let tabHousekeeping: TabHousekeepingPolicy

    public init(
        tabsService: TabsService? = nil,
        session: ChatModeSession? = nil,
        webExtractionOptions: AgentWebExtractionOptions = .baseline,
        tabHousekeeping: TabHousekeepingPolicy = .off
    ) {
        self.tabsService = tabsService
        self.session = session
        self.webExtractionOptions = webExtractionOptions
        self.tabHousekeeping = tabHousekeeping
    }
}
