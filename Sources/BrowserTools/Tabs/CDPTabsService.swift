import Foundation
import CDP
import ToolABI

/// A ``AgentDOMSnapshotting`` backed by an ``AgentDOMService`` driving the page
/// over CDP, mapping the file-processing result type onto the runtime's snapshot
/// type.
final class CDPAgentDOMSnapshotting: AgentDOMSnapshotting {
    private let service: AgentDOMService

    init(service: AgentDOMService) {
        self.service = service
    }

    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool) async throws -> ToolABI.InteractMarkdownResult {
        try await getInteractMarkdown(includeScreenshot, b, includeUrls: includeUrls, signal: nil)
    }

    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool, signal: AbortSignal?) async throws -> ToolABI.InteractMarkdownResult {
        try await getInteractMarkdown(
            includeScreenshot, b,
            serializeOptions: DomSerializeOptions(includeUrls: includeUrls),
            signal: signal)
    }

    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, serializeOptions: DomSerializeOptions, signal: AbortSignal?) async throws -> ToolABI.InteractMarkdownResult {
        let result = try await service.getInteractMarkdown(
            includeScreenshot: includeScreenshot,
            highlight: b,
            serializeOptions: serializeOptions,
            signal: signal
        )
        let diagnostics = ToolABI.InteractMarkdownResult.Diagnostics(
            domError: result.diagnostics.domError,
            serializeError: result.diagnostics.serializeError,
            screenshotError: result.diagnostics.screenshotError
        )
        return ToolABI.InteractMarkdownResult(
            markdown: result.markdown,
            screenshot: result.screenshot,
            diagnostics: diagnostics
        )
    }
}

/// A ``TabHandle`` over a CDP page target. It owns the target session, an
/// ``AgentDOMService`` (for interactive snapshots, click, type, etc.), and the
/// agent-control flags the tab tools read and set.
public final class CDPTabHandle: TabHandle, StepTraceTab {
    let session: CDPTabSession
    let browserTab: CDPBrowserTab
    /// The tab's DOM driver. Public because a host's `onTabCreated` hook wires its own
    /// `sealedRegionProvider` onto it, and that hook runs before the tab has a page to
    /// classify — which is why it is this and not ``interactiveDriver``, the same object
    /// behind a `tabType` gate.
    public let domService: AgentDOMService
    private let snapshotting: CDPAgentDOMSnapshotting
    private let pacer: NavigationPacer?

    private var _title: String?
    private var _tabType: String
    private var _faviconUrl: String?
    private var _userTookOver: Bool = false
    private var _browserAgentControlledAgentId: String?
    private var _chatSessionId: String?
    private var _isAIControlledTab: Bool = false
    private var _isBrowserAgentControlled: Bool = false
    private var _networkLogPath: String?
    private var _networkRecorder: NetworkRecorder?
    private var _viewportBounds: TabViewportBounds?
    /// Whether the user owns this tab (see ``TabHandle/openedByHuman``). Set once
    /// at construction: `true` for a target seeded from the browser, restored, or
    /// adopted live; `false` for one this session opened or a click spawned.
    public let openedByHuman: Bool

    /// Fired after every ``setAIControlledTab`` with the flags as they now stand. The
    /// hook a host hangs a per-tab navigation guard off: the guard installs when the tab
    /// enters agent control and uninstalls when it leaves, and only the transition says
    /// which just happened. Nothing in this package sets it.
    public var onControlStateChange: (@MainActor @Sendable (_ isAIControlled: Bool, _ isAgentControlled: Bool) -> Void)?

    init(
        session: CDPTabSession,
        tabType: String,
        title: String?,
        faviconUrl: String?,
        openedByHuman: Bool,
        pacer: NavigationPacer? = nil
    ) {
        self.session = session
        self.browserTab = CDPBrowserTab(session: session)
        self.domService = AgentDOMService(
            tab: browserTab,
            debuggerFactory: CDPTabDebuggerFactory(),
            cursorAnimator: CDPAgentCursorAnimator(),
            domScriptProvider: CDPDomTreeScriptProvider()
        )
        self.snapshotting = CDPAgentDOMSnapshotting(service: domService)
        self._tabType = tabType
        self._title = title
        self._faviconUrl = faviconUrl
        self.openedByHuman = openedByHuman
        self.pacer = pacer
    }

    // MARK: TabHandle identity

    /// The id everything addresses this tab by: the REAL Chrome target id once it is
    /// known, and only until then the provisional one `createTab` allocated.
    ///
    /// A tab this session opened is created before its Chrome target exists, so it is
    /// born with a `tab-XXXX` placeholder — which is what `manage_tabs open` printed and
    /// what `manage_tabs list` did NOT: list shows targets, keyed by their real ids. Two
    /// namespaces for one tab, and the id the tool told you to use was the one nothing
    /// else accepted. There is one id now, and it is the one that survives this process.
    public var id: String { session.effectiveTargetId ?? session.targetId }
    public var url: String { session.url }

    /// Refreshes the cached url from a URL observed live in the document. The cache is otherwise
    /// written only by the navigation waiter and the read probe, so a page the agent moved with a
    /// click stayed stale here — `manage_tabs list` printed the pre-click URL. Not a navigation:
    /// nothing is reset, this is a reading of the document that is already there.
    func noteObservedURL(_ url: String) { if !url.isEmpty { session.url = url } }

    /// Drops the title this handle was constructed with, so ``title`` reads the session's
    /// live one. The constructor value is a snapshot of the moment the tab was seeded and
    /// shadows every refresh after it.
    func clearCachedTitle() { _title = nil }

    public var title: String? {
        return _title ?? session.title
    }

    public var tabType: String {
        return _tabType
    }

    public var faviconUrl: String? {
        return _faviconUrl
    }

    public var userTookOver: Bool {
        return _userTookOver
    }

    public var agentDOM: AgentDOMSnapshotting? {
        tabType == "website" ? snapshotting : nil
    }

    // MARK: AgentInteractiveTab

    public var interactiveDriver: AgentDOMService? {
        tabType == "website" ? domService : nil
    }

    public var tabLayer: TabLayer { browserTab.getLayer() }

    public func printToPDF(_ options: [String: JSValue]) async throws -> JSValue {
        try await domService.getDebugger().sendCommand(
            "Page", "printToPDF", .object(options.map { ($0.key, $0.value) }))
    }

    // MARK: StepTraceTab (harness step trace)

    public var traceTabId: String { id }
    public var traceTabURL: String { url }
    public var traceTabTitle: String? { title }

    public func captureInteractMarkdown() async throws -> StepTraceMarkdown {
        let result = try await withCDPDeadline(milliseconds: 8_000) {
            try await self.domService.getInteractMarkdown(
                includeScreenshot: true,
                serializeOptions: DomSerializeOptions(includeUrls: true),
                signal: nil
            )
        }
        return StepTraceMarkdown(markdown: result.markdown, screenshotBase64: result.screenshot)
    }

    /// Resolves an `aloha_id` to the serialized node from the DOM service's
    /// MOST RECENT snapshot — a pure read of the already-extracted cache: no CDP
    /// round-trip, no DOM re-extraction, so the step trace never perturbs the page or
    /// the turn. Matches the id the way the tools do (node id first, then the
    /// written-back `aloha-id` attribute), and returns `nil` when the snapshot has no
    /// such node (e.g. the page navigated after the tool ran) or the tab is not an
    /// interactive website tab.
    public func traceDomNode(forAlohaId alohaId: String) -> DomNode? {
        guard tabType == "website", !alohaId.isEmpty else { return nil }
        let nodes = domService.dom
        if let exact = nodes.first(where: { $0.id == alohaId }) { return exact }
        return nodes.first(where: { $0.element.attributes["aloha-id"] == alohaId })
    }

    /// Captures the page's full accessibility tree for the step trace. Enables the
    /// Accessibility domain best-effort first (some pages need it), then requests
    /// the full AX tree.
    public func captureAccessibilityTree() async throws -> JSValue {
        let debug = domService.getDebugger()
        _ = try? await debug.sendCommand("Accessibility", "enable", .object([]))
        return try await debug.sendCommand("Accessibility", "getFullAXTree", .object([]))
    }

    // MARK: TabHandle lifecycle

    public func wake(_ signal: AbortSignal?) async throws -> WakeResult {
        if tabType != "website" { return WakeResult(ok: true) }
        if session.isDestroyed {
            return WakeResult(ok: false, message: "Tab \"\(id)\" is unavailable because it has no live WebContents.")
        }
        do {
            // A tab this session opened navigates by being CREATED — `Target.createTarget`
            // carries the url — so its one fetch never reaches `navigateToURL`, and a
            // pacer hooked only there meters every goto while every `manage_tabs open`
            // walks past. Asked outside the 18s deadline below, which bounds the wake, not
            // the wait for a turn. A tab whose real target already exists is merely being
            // woken, nothing is fetched, and it asks for no turn.
            if session.effectiveTargetId == nil, !session.url.isEmpty {
                try await pacer?(session.url, nil, signal)
            }
            // 18s covers 15s load wait plus attach / Page.enable / bringToFront.
            return try await withCDPDeadline(milliseconds: 18_000) {
                let sessionId = try await self.session.ensureAttached()
                try await self.session.ensurePageEnabled()
                // Hidden/background tab has no compositor. `fromSurface` screenshot
                // and the DOM walker then hang. `Page.bringToFront` is the measured
                // recovery (capture >20s until bringToFront, then ~90ms).
                //
                // BEST-EFFORT ON THE RESPONSE, NEVER ON BROWSER IDENTITY. `try?` is the
                // whole gate: an endpoint that does not implement the method answers
                // `-32601 Method not found`, which arrives as a thrown `CDPError.remote`
                // and is discarded here exactly like a refusal from a Chromium that was
                // already frontmost. The Aloha browser's CDP server is one such endpoint
                // (its `PageDomain` returns `methodNotFound`); so is any future one.
                // Gating on "is this Aloha?" would be wrong twice: this package cannot
                // tell one CDP server from another and must not try (`/json/version`
                // strings are the browser's to change, and `--cdp` points at whatever the
                // user says), and the recovery is a workaround for a CHROMIUM behaviour,
                // not a capability of anyone's browser — the condition that matters is
                // "did this endpoint honour the call", which only the response says.
                _ = try? await withCDPDeadline(milliseconds: 2_000) {
                    try await self.session.client.send(
                        method: "Page.bringToFront", params: [:], sessionId: sessionId)
                }
                let ready = try await self.waitForReadyState(signal)
                await self.refreshViewportBounds()
                if ready { return WakeResult(ok: true) }
                return WakeResult(ok: false, message: "Tab \"\(self.id)\" is unavailable because it failed to wake or finish loading.")
            }
        } catch {
            let message = "\(error)"
            return WakeResult(ok: false, message: "Tab \"\(id)\" is unavailable because it failed to wake: \(message)")
        }
    }

    /// Awaits the tab's *real* main-frame load before a reader sees it, bounded by
    /// a 15s budget. Also refreshes the cached url/title.
    ///
    /// A plain `document.readyState` poll is not enough: a freshly
    /// `Target.createTarget`'d tab reports `readyState == "complete"` on its
    /// **initial `about:blank` document** before the real navigation commits, so a
    /// naive poll would return `true` immediately and the DOM-build would then run
    /// on a blank page (empty content) or stall the eval into the 15s read race.
    /// Instead this waits on the main frame's `Page.lifecycleEvent(name: "load")` /
    /// `Page.frameStoppedLoading`, with the readyState poll kept only as a
    /// cache-refresh and as a fallback for the race where the real load fired
    /// before the listener attached.
    private func waitForReadyState(_ signal: AbortSignal?) async throws -> Bool {
        try await waitForMainFrameLoad(timeoutMs: 15_000, signal: signal)
    }

    /// The shared main-frame load wait used by both the read gate
    /// (`waitForReadyState`) and the post-navigation settle (`waitForTabLoad`).
    ///
    /// Races, against the `timeoutMs` budget: (a) the main frame's CDP load
    /// lifecycle (`Page.lifecycleEvent` `name == "load"`, or
    /// `Page.frameStoppedLoading` for the top-level frame); and (b) a fallback
    /// `document.readyState` poll that only passes once the committed URL is a
    /// **real** document (not the pre-navigation `about:blank`), closing the race
    /// where the load fired before the listener attached. On budget exhaustion it
    /// returns `false` (or `void` for the navigation variant), so a page that
    /// never finishes loading is still bounded.
    @discardableResult
    private func waitForMainFrameLoad(timeoutMs: Int, signal: AbortSignal?) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        let transport = SessionScopedCDPTransport(session: session)
        // The tab's intended target, captured before any poll can overwrite it,
        // so the load flag can tell a real navigation from the initial blank doc.
        let expectedURL = session.url

        // Subscribe BEFORE enabling lifecycle events / navigating-state probing so
        // no `load` emitted in the gap is missed.
        let loadFlag = MainFrameLoadFlag(expectedURL: expectedURL)
        let eventTask = Task { [weak loadFlag] in
            for await event in transport.events() {
                if Task.isCancelled { break }
                loadFlag?.handle(event)
            }
        }
        defer { eventTask.cancel() }

        // Enable named lifecycle milestones (`load`, `DOMContentLoaded`, …) so the
        // `Page.lifecycleEvent` `load` we wait on is delivered. Best-effort: if it
        // fails we still have `Page.frameStoppedLoading` (always emitted once
        // `Page.enable` is on, which `wake`/`navigateToURL` already did) and the
        // readyState fallback.
        _ = try? await transport.send(method: "Page.setLifecycleEventsEnabled", params: ["enabled": .bool(true)])

        // Resolve the top-level frame id so subframe/iframe loads (common on SPAs)
        // do not falsely satisfy the gate.
        if let tree = try? await transport.send(method: "Page.getFrameTree", params: [:]),
           let mainFrameId = tree["frameTree"]?["frame"]?["id"]?.stringValue {
            loadFlag.setMainFrameId(mainFrameId)
        }

        // A `Runtime.evaluate` that throws mid-navigation ("Cannot find context with
        // specified id" on a context swap) must not kill the whole read: leg (a) can
        // still answer. Two consecutive immediate failures are absorbed; a genuinely
        // dead tab then fails fast. A hung eval (Aloha default-tab WKWebView) is
        // different: it is bounded below, does not count toward that fail-fast, and
        // widens its bound rather than retrying at full rate, so we do not pile
        // abandoned evaluates on a frozen renderer. A later lifecycle event can
        // still satisfy the gate.
        //
        // BACKED OFF, NOT ABANDONED: on a re-read leg (a) cannot stand alone.
        // Nothing renavigates, so no `Page.frameNavigated` arrives and
        // `markIfMainFrame` refuses every load milestone until a committed URL
        // exists — and this probe is the only writer of one. Dropping the probe
        // after one overrun would strand a tab that is merely SLOW.
        var probeFailures = 0
        var probeBoundMs = 1_500.0

        while Date() < deadline {
            // `try?` on the pacing sleep below swallows cancellation, so without this
            // exit a cancelled poll spins at full rate until the deadline.
            if Task.isCancelled || signal?.aborted == true { throw SimpleBrowserError("Operation aborted") }

            // (a) The real main-frame load fired since we subscribed.
            if loadFlag.didLoad { refreshCachedURLTitleFromFlag(loadFlag); return true }

            // (b) Fallback poll: readyState + committed URL. Only accept a
            // readyState pass once the live document is the real target (not the
            // initial `about:blank` of a freshly-opened tab), so the blank doc
            // never short-circuits the gate. Refresh the cached url/title only for
            // a real document, so the poll never overwrites the expected target
            // with the transient `about:blank`.
            let probe: JSValue
            do {
                // A frozen Aloha default-tab WKWebView hangs Runtime.evaluate until
                // CDP callTimeout (30s). executeJavaScript's own 15s bound then ate
                // the outer 18s wake deadline, so goto never ran Page.navigate.
                // Bound the probe so one hung eval cannot eat the load wait — and
                // so a lifecycle event that fires during the hang is observed on
                // the next loop instead of after 15s. The bound grows on each
                // overrun (see `probeBoundMs`) so a slow page is not mistaken for
                // a frozen one.
                probe = try await withCDPDeadline(milliseconds: probeBoundMs) {
                    try await self.browserTab.getLayer().executeJavaScript(
                        "({ ready: document.readyState, url: location.href, title: document.title })"
                    )
                }
                probeFailures = 0
            } catch {
                if isCDPDeadlineError(error) {
                    // Cap at 6s: the loop is blind to leg (a) for the length of one
                    // bound, and 6s inside a 15s budget still leaves room to observe
                    // a load. A genuinely frozen renderer costs 4 abandoned
                    // evaluates over the whole wait, not one per 250ms tick.
                    probeBoundMs = min(probeBoundMs * 2, 6_000)
                } else {
                    probeFailures += 1
                    if probeFailures > 2 { throw error }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            if case .object = probe {
                let probedURL = probe["url"]?.stringValue ?? ""
                let isReal = isRealCommittedURL(probedURL, expected: expectedURL)
                // Seed the load flag's committed URL from the LIVE document, so leg
                // (a) can latch on a re-read of an already-loaded tab — there is no
                // fresh `Page.frameNavigated` there, and without a committed URL
                // `markIfMainFrame` refuses every load milestone. `location.href` is
                // read inside the document, so unlike `Page.getFrameTree` it cannot
                // echo back the tab model's merely *intended* url.
                if isReal {
                    session.url = probedURL
                    loadFlag.noteCommittedURL(probedURL)
                    if let title = probe["title"]?.stringValue { session.title = title }
                }
                let state = probe["ready"]?.stringValue ?? ""
                if (state == "interactive" || state == "complete") && isReal {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Refreshes the cached url from the frame-navigated URL the load flag
    /// observed, so a reader that passed via the lifecycle event (without a final
    /// poll) still sees the committed URL.
    private func refreshCachedURLTitleFromFlag(_ flag: MainFrameLoadFlag) {
        if let url = flag.committedURL, !url.isEmpty { session.url = url }
    }

    /// Whether `error` is a ``withCDPDeadline`` timeout rather than a live-page
    /// evaluate failure. Hung probes must not trip the three-strike fail-fast.
    private func isCDPDeadlineError(_ error: Error) -> Bool {
        if let simple = error as? SimpleBrowserError {
            return simple.message.contains("exceeded deadline")
        }
        return "\(error)".contains("exceeded deadline")
    }

    /// Whether the live document `url` is the real committed target rather than
    /// the pre-navigation blank/empty initial document, given the tab's
    /// `expected` target. A tab whose expected target genuinely is `about:blank`
    /// counts a blank document as real; a tab navigating to a real URL but still
    /// showing `about:blank` does not.
    private func isRealCommittedURL(_ url: String, expected: String) -> Bool {
        if url.isEmpty { return false }
        if url == "about:blank" {
            let trimmed = expected.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed == "about:blank"
        }
        return true
    }

    public func viewportBounds() -> TabViewportBounds? {
        guard !session.isDestroyed else { return nil }
        guard let bounds = _viewportBounds, bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    // MARK: Navigation

    /// Navigates the attached page to `url` via `Page.navigate` over the tab's
    /// flat session, then awaits the load to stop before readers see the new url.
    ///
    /// A wired ``NavigationPacer`` is asked for its turn first; `profileId` is the budget
    /// the host charges the navigation against, `nil` when the caller holds none.
    public func navigateToURL(_ url: String, profileId: String? = nil, signal: AbortSignal?) async throws {
        try await pacer?(url, profileId, signal)
        // A pacer can hold a navigation for minutes. An abort raised while it waited must
        // not then be spent loading a page nobody is waiting for.
        if signal?.aborted == true { throw SimpleBrowserError("Operation aborted") }
        let sessionId = try await session.ensureAttached()
        try await session.ensurePageEnabled()
        _ = try await session.client.send(
            method: "Page.navigate",
            params: ["url": .string(url)],
            sessionId: sessionId)
        try await waitForTabLoad(timeoutMs: 15_000, signal: signal)
    }

    /// Steps the session history back one entry. `Page.getNavigationHistory`
    /// yields the entry list + current index; `Page.navigateToHistoryEntry`
    /// targets the prior entry's id. When there is no prior entry the page is
    /// left untouched, matching a no-op `goBack`.
    func goBackHistory(signal: AbortSignal?) async throws {
        let sessionId = try await session.ensureAttached()
        try await session.ensurePageEnabled()
        let history = try await session.client.send(
            method: "Page.getNavigationHistory",
            params: [:],
            sessionId: sessionId)
        let entries = history["entries"]?.arrayValue ?? []
        let currentIndex = Int(history["currentIndex"]?.doubleValue ?? 0)
        let priorIndex = currentIndex - 1
        if priorIndex >= 0, priorIndex < entries.count,
           let entryId = entries[priorIndex]["id"]?.doubleValue {
            _ = try await session.client.send(
                method: "Page.navigateToHistoryEntry",
                params: ["entryId": .number(entryId)],
                sessionId: sessionId)
        }
        try await waitForTabLoad(timeoutMs: 10_000, signal: signal)
    }

    /// Settles after a navigation: awaits the real main-frame load, refreshing the
    /// cached url/title, bounded by `timeoutMs`. Shares `waitForMainFrameLoad` with
    /// the read gate so both observe the *real* navigation lifecycle rather than
    /// the pre-navigation `about:blank` readyState.
    private func waitForTabLoad(timeoutMs: Int, signal: AbortSignal?) async throws {
        _ = try await waitForMainFrameLoad(timeoutMs: timeoutMs, signal: signal)
    }

    /// Waits for the page to settle under `options`: tracks the in-flight
    /// (non-persistent) request count from CDP Network events, injects the
    /// debounced DOM-stability observer, and polls the portable
    /// ``PageReadinessClassifier`` every 100ms. The CDP transport is the injected
    /// boundary; it carries the debugger-attached network and DOM observation the
    /// classifier consumes.
    func waitForReady(_ options: PageReadinessOptions, signal: AbortSignal?) async -> PageReadinessResult {
        let classifier = PageReadinessClassifier()
        let start = Date()
        let tracker = PageReadinessNetworkTracker(classifier: classifier)
        let transport = SessionScopedCDPTransport(session: session)

        _ = try? await transport.send(method: "Network.enable", params: [:])
        let eventTask = Task { [weak tracker] in
            for await event in transport.events() {
                if Task.isCancelled { break }
                tracker?.handle(event)
            }
        }
        defer { eventTask.cancel() }

        // The DOM-stability observer resolves once the main node stops mutating;
        // record when that happens to derive `domStableForMs`.
        let domStable = DomStableTimestamp()
        let stabilityTask = Task { [weak browserTab] in
            guard let browserTab else { return }
            _ = try? await browserTab.getLayer().executeJavaScript(
                buildDomStabilityScript(stableTimeMs: options.domStableTimeMs))
            domStable.markStable()
        }
        defer { stabilityTask.cancel() }

        while true {
            // `try?` on the pacing sleep below swallows cancellation, so without the
            // `Task.isCancelled` exit a cancelled wait spins at full rate until the
            // timeout.
            if Task.isCancelled || signal?.aborted == true {
                return PageReadinessResult(success: false, waitedMs: elapsedMs(since: start), reason: .aborted)
            }
            let elapsed = elapsedMs(since: start)
            if elapsed >= options.timeoutMs {
                return PageReadinessResult(success: false, waitedMs: elapsed, reason: .timeout)
            }
            if session.isDestroyed {
                return PageReadinessResult(success: false, waitedMs: elapsed, reason: .error)
            }
            let inFlightCount = tracker.inFlightCount()
            let networkIdleForMs = tracker.networkIdleForMs(threshold: options.networkIdleThreshold, now: Date())
            let domStableForMs = domStable.stableForMs(now: Date())
            if classifier.isReady(
                elapsedMs: elapsed,
                networkIdleForMs: networkIdleForMs,
                domStableForMs: domStableForMs,
                inFlightCount: inFlightCount,
                options: options) {
                return PageReadinessResult(success: true, waitedMs: elapsed, reason: .ready)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    /// Refreshes the cached layout-metrics viewport size from the page (called
    /// during wake so the synchronous ``viewportBounds()`` reader has a value).
    private func refreshViewportBounds() async {
        guard let sessionId = try? await session.ensureAttached() else { return }
        guard let metrics = try? await session.client.send(method: "Page.getLayoutMetrics", params: [:], sessionId: sessionId) else { return }
        let viewport = metrics["cssLayoutViewport"]
        let width = viewport?["clientWidth"]?.doubleValue ?? 0
        let height = viewport?["clientHeight"]?.doubleValue ?? 0
        _viewportBounds = TabViewportBounds(width: Int(width), height: Int(height))
    }

    public func startNetworkRecording(logPath: String) {
        if _networkRecorder != nil { return }
        _networkLogPath = logPath
        // Directory first: the writer creates its file in it.
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let writer = NetworkLogWriter(path: logPath)
        let recorder = NetworkRecorder(transport: SessionScopedCDPTransport(session: session)) { record in
            writer.append(record)
        }
        _networkRecorder = recorder
        Task { [session, recorder] in
            _ = try? await session.ensureAttached()
            await recorder.start()
        }
    }

    // MARK: AgentControllableTab

    public var browserAgentControlledAgentId: String? {
        return _browserAgentControlledAgentId
    }

    public var chatSessionId: String? {
        get { return _chatSessionId }
        set { _chatSessionId = newValue; }
    }

    public var isAIControlledTab: Bool {
        return _isAIControlledTab
    }

    public var isBrowserAgentControlled: Bool {
        return _isBrowserAgentControlled
    }

    public func setAIControlledTab(_ controlled: Bool, agentId: String?) {
        _isAIControlledTab = controlled
        if controlled {
            _isBrowserAgentControlled = false
            _browserAgentControlledAgentId = nil
        } else {
            _isBrowserAgentControlled = true
            _browserAgentControlledAgentId = agentId
        }
        onControlStateChange?(_isAIControlledTab, _isBrowserAgentControlled)
    }

}



/// A ``TabsModel`` over a CDP browser. It seeds the open page targets from
/// `Target.getTargets`, creates tabs via `Target.createTarget`, closes via
/// `Target.closeTarget`, and reads legacy tab context as the page body text.
public final class CDPTabsModel: TabsModel {
    private let client: CDPClient
    private var tabs: [String: CDPTabHandle] = [:]
    private var order: [String] = []
    private var _activeTabId: String?
    private var seeded = false

    /// Ids ``closeTab`` closed. `Target.closeTarget` is fire-and-forget, so a browser
    /// that still lists a closed target must not let ``adoptLiveTarget`` resurrect it.
    private var closedTargetIds: Set<String> = []

    /// The agent-controller / chat-session identity attributed to a tab adopted
    /// from a click-spawned target, mirroring how ``createTab`` attributes an
    /// agent-opened tab. `nil` (the default) registers the adopted tab as a plain
    /// agent-controlled website tab keyed by its real target id.
    private let agentControllerId: String?
    private let sessionId: String?

    /// Whether the tabs already open when this model seeded belong to a HUMAN. True for
    /// the user's own browser, which is what `--cdp` reaches: those tabs predate us and
    /// `manage_tabs close` refuses them. False for a browser alohajet launched, where
    /// there is no user to protect and the seeded `about:blank` is our own.
    private let seededTabsAreHuman: Bool

    /// Handed to every handle this model builds, so both doors a navigation leaves by are
    /// metered by the same gate. See ``NavigationPacer``.
    private let navigationPacer: NavigationPacer?

    /// Announced once per ``CDPTabHandle``, from ``register`` — the single point every
    /// creation path funnels through, so a tab cannot reach a host unannounced and end up
    /// with neither the host's sealed-region handling nor its navigation guard.
    private let onTabCreated: (@MainActor @Sendable (CDPTabHandle) -> Void)?

    public init(
        client: CDPClient,
        agentControllerId: String? = nil,
        sessionId: String? = nil,
        seededTabsAreHuman: Bool = true,
        navigationPacer: NavigationPacer? = nil,
        onTabCreated: (@MainActor @Sendable (CDPTabHandle) -> Void)? = nil
    ) {
        self.client = client
        self.agentControllerId = agentControllerId
        self.sessionId = sessionId
        self.seededTabsAreHuman = seededTabsAreHuman
        self.navigationPacer = navigationPacer
        self.onTabCreated = onTabCreated
    }

    public var activeTabId: String? {
        return _activeTabId
    }

    public func setActiveTabId(_ id: String?) {
        _activeTabId = id;
    }

    public var tabsById: [String: TabHandle] {
        var result: [String: TabHandle] = [:]
        for (key, value) in tabs { result[key] = value }
        return result
    }

    public var orderedTabs: [TabHandle] {
        return order.compactMap { tabs[$0] }
    }

    public func getOrRestoreTab(_ id: String, restoreIfNeeded: Bool) -> TabHandle? {
        if let existing = resolveLocked(id) { return existing }
        guard restoreIfNeeded else { return nil }
        // The id names a live Chrome page target not yet tracked here (e.g. a tab
        // addressed by its real target id, or opened outside this model). Restore
        // a handle bound to that existing target so it can be read/driven.
        let session = CDPTabSession(client: client, targetId: id, sessionId: nil, url: "", title: nil)
        let handle = CDPTabHandle(
            session: session,
            tabType: "website",
            title: nil,
            faviconUrl: nil,
            openedByHuman: true,
            pacer: navigationPacer)
        register(handle)
        return handle
    }

    public func tab(_ id: String) -> TabHandle? {
        return resolveLocked(id)
    }

    /// Resolves a handle by its registered (external) id or by the real Chrome
    /// target id it attached to, so a tab can be addressed by either — an
    /// agent-opened tab is keyed by a provisional id until it attaches, after
    /// which `Target.getTargets` reports a different real target id.
    private func resolveLocked(_ id: String) -> CDPTabHandle? {
        if let direct = tabs[id] { return direct }
        return tabs.values.first { $0.session.effectiveTargetId == id }
    }

    public func createTab(_ spec: TabCreateSpec) -> TabHandle {
        // Allocation-only: the real Chrome target is created lazily on first
        // attach, so this returns a tab object synchronously before navigation
        // settles.
        let externalId = "tab-\(UUID().uuidString.prefix(12))"
        let session = CDPTabSession(client: client, targetId: externalId, sessionId: nil, url: spec.url, createOnAttach: true)
        let handle = CDPTabHandle(
            session: session,
            tabType: spec.tabType,
            title: nil,
            faviconUrl: nil,
            openedByHuman: spec.openedByHuman,
            pacer: navigationPacer)
        // Registered — and so announced — BEFORE the control flags are written: a host
        // that hangs its navigation guard off `onControlStateChange` has to be listening
        // for the transition that puts this tab under the agent, and that transition is
        // the next line. Registration reads nothing the flags write.
        register(handle)
        if let agentId = spec.agentControllerId, !spec.openedByHuman {
            handle.setAIControlledTab(false, agentId: agentId)
            handle.chatSessionId = spec.sessionId ?? agentId
        }
        return handle
    }

    private func register(_ handle: CDPTabHandle) {
        tabs[handle.id] = handle
        if !order.contains(handle.id) { order.append(handle.id) }
        onTabCreated?(handle)
    }

    public func closeTab(_ id: String, skipConfirm: Bool) async {
        // Resolved, not indexed: a tab is registered under the id it had when it was
        // created, and an agent-opened one outgrows that id the moment its real Chrome
        // target exists. Indexing `tabs[id]` with the id the tool was CALLED with then
        // found nothing and returned silently — a close that reported success and closed
        // nothing.
        guard let handle = resolveLocked(id) else { return }
        let registeredId = tabs.first { $0.value === handle }?.key ?? id
        tabs.removeValue(forKey: registeredId)
        order.removeAll { $0 == registeredId }
        if _activeTabId == registeredId || _activeTabId == id { _activeTabId = nil }
        closedTargetIds.insert(registeredId)
        closedTargetIds.insert(id)
        handle.session.markDestroyed()
        if let realTargetId = handle.session.effectiveTargetId {
            closedTargetIds.insert(realTargetId)
            _ = try? await client.send(method: "Target.closeTarget", params: ["targetId": .string(realTargetId)])
        }
    }

    public func getTabContext(windowId: String, tab: TabHandle, signal: AbortSignal?) async throws -> TabReadContext? {
        try await getTabContext(windowId: windowId, tab: tab, signal: signal, timeoutMs: 15_000)
    }

    func getTabContext(
        windowId: String,
        tab: TabHandle,
        signal: AbortSignal?,
        timeoutMs: Int
    ) async throws -> TabReadContext? {
        try await raceContextTimeout(parent: signal, timeoutMs: timeoutMs, tabId: tab.id) { childSignal in
            try await self.getTabContextInternal(windowId: windowId, tab: tab, signal: childSignal)
        }
    }

    /// Extracts the tab's read context without a timeout, honoring `signal` at the
    /// abort checkpoints. Returns nil when the tab is not CDP-backed.
    func getTabContextInternal(
        windowId: String,
        tab: TabHandle,
        signal: AbortSignal?
    ) async throws -> TabReadContext? {
        guard let cdpTab = tab as? CDPTabHandle else { return nil }
        if signal?.aborted == true { throw AbortSignalError("Aborted") }
        let result = try await cdpTab.browserTab.getLayer().executeJavaScript(
            "(document.body && document.body.innerText) ? document.body.innerText : ''"
        )
        if signal?.aborted == true { throw AbortSignalError("Aborted") }
        let text = result.stringValue ?? ""
        let type = cdpTab.tabType == "website" ? "web" : cdpTab.tabType
        return TabReadContext(data: text, type: type)
    }

    /// Seeds the model from the browser's currently-open page targets. Safe to
    /// call repeatedly; it only seeds once.
    public func seedFromBrowser() async {
        if seeded { return }
        seeded = true
        guard let result = try? await client.send(method: "Target.getTargets", params: [:]) else { return }
        guard let infos = result["targetInfos"]?.arrayValue else { return }
        for info in infos {
            guard info["type"]?.stringValue == "page" else { continue }
            guard let targetId = info["targetId"]?.stringValue else { continue }
            let url = info["url"]?.stringValue ?? ""
            let title = info["title"]?.stringValue
            let session = CDPTabSession(client: client, targetId: targetId, sessionId: nil, url: url, title: title)
            let handle = CDPTabHandle(
                session: session,
                tabType: "website",
                title: title,
                    faviconUrl: nil,
                openedByHuman: seededTabsAreHuman,
                pacer: navigationPacer)
            register(handle)
        }
    }

    /// Refresh the cached url and title of every tracked tab from the browser's live
    /// target list — one `Target.getTargets` for the whole window.
    ///
    /// Both are caches. `url` is written by the navigation waiter, the read probe and the
    /// click's live-URL read; `title` was written by the read probe ALONE, and only on
    /// the polling leg of the load wait — so a tab that finished loading via the
    /// lifecycle event kept the title it was born with (`nil`, rendered "Untitled"), and
    /// a page the agent navigated kept the OLD page's title against the new URL. Nothing
    /// else refreshes a tab the tools never touched. This does, for all of them, for one
    /// round-trip.
    public func refreshTabMetadata() async {
        guard let infos = await pageTargetInfos() else { return }
        for info in infos {
            guard let targetId = info["targetId"]?.stringValue,
                  let handle = resolveLocked(targetId) else { continue }
            let url = info["url"]?.stringValue ?? ""
            // A tab still on its initial blank document has not committed the URL it was
            // opened for; overwriting the intended target with `about:blank` would make
            // the load wait expect the wrong page.
            if !url.isEmpty, url != "about:blank" || handle.session.url.isEmpty {
                handle.session.url = url
            }
            if let title = info["title"]?.stringValue, !title.isEmpty {
                handle.session.title = title
                handle.clearCachedTitle()
            }
        }
    }
}

extension CDPTabsModel: ClickSpawnedTabAdopting {
    public func currentPageTargetIds() async -> Set<String> {
        await pageTargetIds()
    }

    /// Re-reads the browser's page targets and adopts each one that is genuinely
    /// new: not in `previous`, not already tracked (by registered or real target
    /// id), with a navigable non-blank url. Each adopted target is bound to a
    /// handle over the EXISTING target (no new target is created) and registered
    /// as an agent-controlled background tab.
    public func adoptSpawnedTabs(notIn previous: Set<String>) async -> [AdoptedTab] {
        guard let infos = await pageTargetInfos() else { return [] }
        var adopted: [AdoptedTab] = []
        for info in infos {
            guard let targetId = info["targetId"]?.stringValue, !targetId.isEmpty else { continue }
            if previous.contains(targetId) { continue }
            if resolveLocked(targetId) != nil { continue }
            let url = info["url"]?.stringValue ?? ""
            let trimmedUrl = url.trimmingCharacters(in: .whitespaces)
            if trimmedUrl.isEmpty || trimmedUrl == "about:blank" { continue }
            if case .rejected = validateOpenUrl(url) { continue }
            let title = info["title"]?.stringValue
            // Bind to the existing target (no createOnAttach) so a later read wakes
            // the live page rather than opening a duplicate.
            let session = CDPTabSession(client: client, targetId: targetId, sessionId: nil, url: url, title: title)
            let handle = CDPTabHandle(
                session: session,
                tabType: "website",
                title: title,
                    faviconUrl: nil,
                openedByHuman: false,
                pacer: navigationPacer)
            // Announced before the control flags, for the reason `createTab` gives.
            register(handle)
            handle.setAIControlledTab(false, agentId: agentControllerId)
            handle.chatSessionId = sessionId ?? agentControllerId
            adopted.append(AdoptedTab(id: handle.id, url: handle.url, title: handle.title))
        }
        return adopted
    }

    private func pageTargetIds() async -> Set<String> {
        guard let infos = await pageTargetInfos() else { return [] }
        var ids: Set<String> = []
        for info in infos {
            guard let targetId = info["targetId"]?.stringValue else { continue }
            ids.insert(targetId)
        }
        return ids
    }

    /// Reads `Target.getTargets` and returns the `page`-type target info entries,
    /// or `nil` when the call fails (so a transport error is not mistaken for "no
    /// tabs spawned").
    private func pageTargetInfos() async -> [JSValue]? {
        guard let result = try? await client.send(method: "Target.getTargets", params: [:]),
              let infos = result["targetInfos"]?.arrayValue else { return nil }
        return infos.filter { $0["type"]?.stringValue == "page" }
    }
}

extension CDPTabsModel: LiveTabMetadataRefreshing {}

extension CDPTabsModel: LivePageTargetAdopting {
    /// Human-opened with no agent attribution (like ``seedFromBrowser``, unlike
    /// ``adoptSpawnedTabs``): the tab is the user's, and adopting it must not hand
    /// it to the AI overlay.
    public func adoptLiveTarget(_ id: String) async -> TabHandle? {
        if let existing = resolveLocked(id) { return existing }
        if closedTargetIds.contains(id) { return nil }
        guard let infos = await pageTargetInfos(),
              let info = infos.first(where: { $0["targetId"]?.stringValue == id })
        else { return nil }
        let url = info["url"]?.stringValue ?? ""
        let title = info["title"]?.stringValue
        let session = CDPTabSession(client: client, targetId: id, sessionId: nil, url: url, title: title)
        let handle = CDPTabHandle(
            session: session,
            tabType: "website",
            title: title,
            faviconUrl: nil,
            openedByHuman: true,
            pacer: navigationPacer)
        register(handle)
        return handle
    }
}

/// Tracks the in-flight (non-persistent) request count from CDP Network events
/// for the page-readiness waiter, and the timestamp at which the network most
/// recently fell to or below the idle threshold.
final class PageReadinessNetworkTracker {
    private let classifier: PageReadinessClassifier
    private var inFlight: Set<String> = []
    private var idleSince: Date?

    init(classifier: PageReadinessClassifier) {
        self.classifier = classifier
    }

    func handle(_ event: CDPEvent) {
        switch event.method {
        case "Network.requestWillBeSent":
            guard let requestId = event.params.string("requestId"),
                  let request = event.params["request"],
                  let url = request.string("url") else { return }
            if url.hasPrefix("data:") { return }
            let type = event.params.string("type") ?? ""
            let accept = request["headers"]?.string("Accept")
            let req = PageReadinessRequest(url: url, type: type, acceptHeader: accept)
            if classifier.isPersistentConnection(req) { return }
            inFlight.insert(requestId)
            idleSince = nil
        case "Network.loadingFinished", "Network.loadingFailed":
            guard let requestId = event.params.string("requestId") else { return }
            inFlight.remove(requestId)
        default:
            break
        }
    }

    func inFlightCount() -> Int {
        return inFlight.count
    }

    func networkIdleForMs(threshold: Int, now: Date) -> Int {
        if inFlight.count <= threshold {
            if idleSince == nil { idleSince = now }
            return Int(now.timeIntervalSince(idleSince!) * 1000)
        } else {
            idleSince = nil
            return 0
        }
    }
}

final class DomStableTimestamp {
    private var stableAt: Date?

    func markStable() {
        if stableAt == nil { stableAt = Date() };
    }

    func stableForMs(now: Date) -> Int {
        guard let stableAt else { return 0 }
        return Int(now.timeIntervalSince(stableAt) * 1000)
    }
}

/// Observes a tab session's CDP `Page` events to detect the **real** main-frame
/// load.
///
/// The flag is structurally immune to a "blank-doc complete" false-positive:
/// `didLoad` latches only when the top-level frame fires a load milestone
/// (`Page.lifecycleEvent` `name == "load"`, or `Page.frameStoppedLoading`)
/// **while its committed URL is a real document** (not the freshly-created tab's
/// initial `about:blank`). A load fired for the initial blank document is
/// ignored; subframe/iframe loads are ignored (so an SPA's iframes never satisfy
/// the gate). `Page.frameNavigated` for the main frame records the committed URL,
/// both to gate the load and to refresh the cached url without a final poll.
///
/// `expectsRealURL` is the tab's intended target: when it is empty / `about:blank`
/// the tab is *legitimately* a blank tab, so a load of `about:blank` does count.
final class MainFrameLoadFlag {
    private var _mainFrameId: String?
    private var _didLoad = false
    private var _committedURL: String?
    private let expectsRealURL: Bool

    init(expectedURL: String) {
        let trimmed = expectedURL.trimmingCharacters(in: .whitespaces)
        self.expectsRealURL = !trimmed.isEmpty && trimmed != "about:blank"
    }

    func setMainFrameId(_ id: String) {
        if _mainFrameId == nil { _mainFrameId = id };
    }

    var didLoad: Bool { return _didLoad }
    var committedURL: String? { return _committedURL }

    /// Records an OBSERVED committed URL (the live document's `location.href`),
    /// without the navigation reset `Page.frameNavigated` performs — this is not a
    /// navigation, it is a reading of the document that is already there.
    func noteCommittedURL(_ url: String) {
        if !url.isEmpty { _committedURL = url }
    }

    func handle(_ event: CDPEvent) {
        switch event.method {
        case "Page.frameNavigated":
            guard let frame = event.params["frame"] else { return }
            // A top-level navigation has no parentId.
            let isTopLevel = frame["parentId"]?.stringValue == nil
            guard isTopLevel else { return }
            let frameId = frame["id"]?.stringValue
            let url = frame["url"]?.stringValue ?? ""
            if _mainFrameId == nil { _mainFrameId = frameId }
            if !url.isEmpty { _committedURL = url }
            // A new top-level navigation supersedes any earlier (e.g. about:blank)
            // load, so the load flag resets on navigation start.
            _didLoad = false
        case "Page.lifecycleEvent":
            guard event.params["name"]?.stringValue == "load" else { return }
            markIfMainFrame(event.params["frameId"]?.stringValue)
        case "Page.frameStoppedLoading":
            markIfMainFrame(event.params["frameId"]?.stringValue)
        default:
            break
        }
    }

    private func markIfMainFrame(_ frameId: String?) {
        // Count the event only when it targets the resolved main frame, so an
        // SPA's subframe/iframe loads never falsely satisfy the gate.
        guard let main = _mainFrameId, frameId == main else { return }
        // Gate on the committed URL being the real target: ignore a load of the
        // freshly-created tab's initial about:blank when a real URL is expected.
        if expectsRealURL {
            guard let url = _committedURL, isRealURL(url) else { return }
        }
        _didLoad = true
    }

    private func isRealURL(_ url: String) -> Bool {
        !url.isEmpty && url != "about:blank"
    }
}

final class TimeoutFlag {
    private var _value = false
    var value: Bool {
        get { return _value }
        set { _value = newValue; }
    }
}

/// Races a tab-context `extraction` against a `timeoutMs` deadline: a fresh
/// ``AbortController`` is created (chained to the `parent` signal so an external
/// abort cancels the extraction), the extraction runs against that child signal,
/// and a timer races it. On timeout the child signal is aborted and `nil` is
/// returned; an abort-shaped error from the extraction returns `nil`; an error
/// that arrives after the timeout fired is logged and swallowed to `nil`; any
/// other error is rethrown.
func raceContextTimeout<T: Sendable>(
    parent: AbortSignal?,
    timeoutMs: Int,
    tabId: String,
    extraction: @escaping @MainActor @Sendable (AbortSignal) async throws -> T?
) async throws -> T? {
    let controller = AbortController()
    var detach: (() -> Void)?
    if let parent {
        if parent.aborted {
            controller.abort(parent.reason)
        } else {
            let token = parent.onAbort { [weak controller] in controller?.abort(parent.reason) }
            detach = { parent.removeAbortListener(token) }
        }
    }
    defer { detach?() }

    let timedOut = TimeoutFlag()
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await runRaceExtraction(extraction, controller: controller, timedOut: timedOut, tabId: tabId)
        }
        group.addTask {
            try await runRaceTimeout(timeoutMs: timeoutMs, controller: controller, timedOut: timedOut, tabId: tabId)
        }
        defer { group.cancelAll() }
        let result = try await group.next() ?? nil
        return result
    }
}

@MainActor
private func runRaceExtraction<T: Sendable>(
    _ extraction: @escaping @MainActor @Sendable (AbortSignal) async throws -> T?,
    controller: AbortController,
    timedOut: TimeoutFlag,
    tabId: String
) async throws -> T? {
    do {
        return try await extraction(controller.signal)
    } catch {
        if isAbortError(error) { return nil }
        if timedOut.value {
            agentLog(.warn, "[CDPTabsModel] Tab \(tabId) context error after timeout: \(error)")
            return nil
        }
        throw error
    }
}

@MainActor
private func runRaceTimeout<T: Sendable>(
    timeoutMs: Int,
    controller: AbortController,
    timedOut: TimeoutFlag,
    tabId: String
) async throws -> T? {
    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
    if Task.isCancelled { throw CancellationError() }
    timedOut.value = true
    agentLog(.warn, "[CDPTabsModel] Tab \(tabId) context resolution timed out after \(timeoutMs)ms")
    controller.abort("timeout")
    return nil
}

public final class CDPTabsWindow: TabsWindow {
    public let id: String
    private let model: CDPTabsModel

    public init(id: String, model: CDPTabsModel) {
        self.id = id
        self.model = model
    }

    public var tabs: TabsModel { model }
}

public final class CDPTabsService: TabsService {
    private let cdpWindow: CDPTabsWindow

    public init(window: CDPTabsWindow) {
        self.cdpWindow = window
    }

    public var window: TabsWindow? { cdpWindow }
}

/// Builds a fully CDP-backed ``TabsService`` from a connected ``CDPClient``: the
/// window, the tabs model (seeded from the browser's open page targets), the
/// per-tab agent DOM, debugger, cursor animator, and document-walker provider.
/// A consumer that supplies only a `CDPClient` gets a `manage_tabs` / `tab_read`
/// / click path that works without any hand-written browser code.
///
/// `navigationPacer` and `onTabCreated` are the whole injection surface for a host that
/// wants more than that: the pacer gates every navigation (see ``NavigationPacer``), and
/// `onTabCreated` hands over each ``CDPTabHandle`` the moment it is registered, before
/// anything has driven it — which is where a host installs its own
/// `domService.sealedRegionProvider` and `onControlStateChange`.
///
/// Two consequences of "the moment it is registered", both of which bite a host that
/// reads instead of installs:
///
/// - The control flags and `chatSessionId` are written on the line AFTER registration,
///   deliberately, so a host listening on `onControlStateChange` sees the transition that
///   puts the tab under the agent rather than missing it. A hook that READS
///   `isAIControlledTab` or `chatSessionId` therefore always reads the pre-transition
///   value. Listen; do not read.
/// - For tabs seeded from the browser the hook fires during this call, before the
///   `TabsService` exists. A closure that needs the service itself has nothing to capture
///   for those tabs — hang what it needs off the handle, or wire the seeded tabs from the
///   host after this returns.
public func makeCDPBrowserTabsService(
    client: CDPClient,
    windowId: String = "cdp-window",
    seed: Bool = true,
    agentControllerId: String? = nil,
    sessionId: String? = nil,
    seededTabsAreHuman: Bool = true,
    navigationPacer: NavigationPacer? = nil,
    onTabCreated: (@MainActor @Sendable (CDPTabHandle) -> Void)? = nil
) async -> TabsService {
    let model = CDPTabsModel(
        client: client,
        agentControllerId: agentControllerId,
        sessionId: sessionId,
        seededTabsAreHuman: seededTabsAreHuman,
        navigationPacer: navigationPacer,
        onTabCreated: onTabCreated)
    if seed { await model.seedFromBrowser() }
    let window = CDPTabsWindow(id: windowId, model: model)
    return CDPTabsService(window: window)
}

/// Appends captured network records to a `<tabId>.jsonl` file, one JSON object
/// per line, serializing each record's fields in a stable order.
final class NetworkLogWriter {
    private let path: String

    init(path: String) {
        self.path = path
        Self.createIfMissing(path)
    }

    /// Creates the log 0600, never the 0644 `createFile`/`Data.write` default: this file
    /// holds one browsing session's request metadata and response bodies, and on a shared
    /// machine 0644 hands it to every other account. Done HERE rather than at the call
    /// site because `append`'s fallback path creates the file too.
    static func createIfMissing(_ path: String) {
        if FileManager.default.fileExists(atPath: path) { return }
        FileManager.default.createFile(
            atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }

    func append(_ record: NetworkRecord) {
        let line = Self.encode(record) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        Self.createIfMissing(path)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func encode(_ record: NetworkRecord) -> String {
        var members: [(String, JSValue)] = [
            ("ts", .string(record.ts)),
            ("type", .string(record.type)),
            ("requestId", .string(record.requestId)),
            ("method", .string(record.method)),
            // `?access_token=…` is as much a credential as an `Authorization:` header.
            // Reuses ToolABI's `redactSensitiveUrlParams`, the same filter element hrefs go
            // through, so a URL is masked the same way wherever it is written down.
            ("url", .string(redactSensitiveUrlParams(record.url)))
        ]
        if let resourceType = record.resourceType { members.append(("resourceType", .string(resourceType))) }
        if let requestHeaders = record.requestHeaders { members.append(("requestHeaders", headers(requestHeaders))) }
        // The request body is where a login POSTs the password and an API POSTs the token.
        // The log keeps that a request HAD one, and how big, never what was in it.
        if let postData = record.postData {
            members.append(("postData", .string("\(REDACTED_VALUE) (\(postData.count) chars)")))
        }
        if let status = record.status { members.append(("status", .number(Double(status)))) }
        if let statusText = record.statusText { members.append(("statusText", .string(statusText))) }
        if let mimeType = record.mimeType { members.append(("mimeType", .string(mimeType))) }
        if let responseHeaders = record.responseHeaders { members.append(("responseHeaders", headers(responseHeaders))) }
        if let bodySize = record.bodySize { members.append(("bodySize", .number(Double(bodySize)))) }
        // RESPONSE BODIES ARE KEPT — a network log with no bodies answers nothing — but
        // the credential-named fields in them are not. A login response's
        // `{"access_token": "…"}` is a session in a file.
        if let body = record.body { members.append(("body", .string(redactCredentialFields(in: body)))) }
        if let errorText = record.errorText { members.append(("errorText", .string(errorText))) }
        return JSValue.object(members).stringify()
    }

    /// Header names whose entire VALUE is a credential, masked on the way to disk.
    ///
    /// The NAME survives — the shape of the request is why a network log gets opened
    /// at all — and only the value becomes `***`.
    static let sensitiveHeaderNames: Set<String> = [
        "api-key", "authorization", "cookie", "proxy-authenticate", "proxy-authorization",
        "set-cookie", "www-authenticate", "x-access-token", "x-amz-security-token",
        "x-api-key", "x-auth-token", "x-csrf-token", "x-refresh-token", "x-session-token",
    ]

    static let REDACTED_VALUE = "***"

    /// Header names whose value is a whole URL. Their value is not itself a credential —
    /// masking it outright would throw away the request shape a log gets opened for — but
    /// it carries the SAME query string `record.url` is redacted for, so `?token=…` on the
    /// page reaches disk through `Referer` on every subresource it requests unless the same
    /// filter runs here.
    static let urlValuedHeaderNames: Set<String> = [
        "content-location", "location", "referer",
    ]

    /// Header names lowercased for the match, so `Set-Cookie` and `set-cookie` redact alike.
    static func redactHeaderValue(name: String, value: String) -> String {
        let lowered = name.lowercased()
        if sensitiveHeaderNames.contains(lowered) { return REDACTED_VALUE }
        if urlValuedHeaderNames.contains(lowered) { return redactSensitiveUrlParams(value) }
        return value
    }

    /// Credential-named JSON / form fields masked wherever they appear in a logged body.
    /// Bare `token` and `key` are absent on purpose — `key` names half the maps in a
    /// JSON document, and masking those would gut the log it is written into.
    static let credentialFieldNames = [
        "access_token", "accesstoken", "api-key", "api_key", "apikey", "auth_token",
        "authorization", "authtoken", "client_secret", "id_token", "passwd",
        "password", "refresh_token", "secret", "session_token", "x-api-key",
    ]

    /// A credential's value stops at the first character that cannot belong to one, so
    /// masking one inside prose does not swallow the delimiter after it.
    static let credentialValueClass = #"[^&\s"'<>,;)\]}\\]*"#

    /// Masks the value of every credential-named JSON field or `name=value` pair. The JSON
    /// pass consumes backslash escapes inside the string it replaces, so a value containing
    /// `\"` cannot end the match early and leave broken JSON behind.
    static func redactCredentialFields(in text: String) -> String {
        let names = credentialFieldNames
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        var result = mask(text, #"(?i)("(?:\#(names))"\s*:\s*")(?:[^"\\]|\\.)*""#, "$1***\"")
        result = mask(result, #"(?i)\b((?:\#(names))=)\#(credentialValueClass)"#, "$1***")
        return result
    }

    private static func mask(_ text: String, _ pattern: String, _ replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: replacement)
    }

    private static func headers(_ map: [String: String]) -> JSValue {
        .object(map.sorted { $0.key < $1.key }
            .map { ($0.key, JSValue.string(redactHeaderValue(name: $0.key, value: $0.value))) })
    }
}
