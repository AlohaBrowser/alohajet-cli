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

    func getInteractMarkdown(_ includeScreenshot: Bool, _ highlight: Bool, includeUrls: Bool) async throws -> ToolABI.InteractMarkdownResult {
        try await getInteractMarkdown(includeScreenshot, highlight, includeUrls: includeUrls, signal: nil)
    }

    func getInteractMarkdown(_ includeScreenshot: Bool, _ highlight: Bool, includeUrls: Bool, signal: AbortSignal?) async throws -> ToolABI.InteractMarkdownResult {
        try await getInteractMarkdown(
            includeScreenshot, highlight,
            serializeOptions: DomSerializeOptions(includeUrls: includeUrls),
            signal: signal)
    }

    func getInteractMarkdown(_ includeScreenshot: Bool, _ highlight: Bool, serializeOptions: DomSerializeOptions, signal: AbortSignal?) async throws -> ToolABI.InteractMarkdownResult {
        let result = try await service.getInteractMarkdown(
            includeScreenshot: includeScreenshot,
            highlight: highlight,
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
/// ``AgentDOMService`` (for interactive snapshots, click, type, etc.), and the tab's
/// attribution.
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

    public let tabType: String
    private var networkRecorder: NetworkRecorder?
    private var cachedViewportBounds: TabViewportBounds?
    /// Whose this tab is by the tabs model's own rule, decided once by its one entry
    /// function.
    private let owner: TabOwner
    /// Asked for what only the browser knows; `nil` when the browser offers no source.
    private let attributionSource: TabAttributionSource?

    /// Whose this tab is and whether it is the foreground tab, worked out each time it is
    /// read: the one place the attribution source's answers meet the tabs model's own
    /// rule.
    public var attribution: TabAttribution {
        guard let attributionSource else { return TabAttribution(owner: owner) }
        return TabAttribution(owner: owner, foreground: attributionSource.foregroundTabId == id)
    }

    init(
        session: CDPTabSession,
        tabType: String,
        owner: TabOwner,
        attributionSource: TabAttributionSource?,
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
        self.tabType = tabType
        self.owner = owner
        self.attributionSource = attributionSource
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

    public var title: String? { session.title }

    public var faviconUrl: String? { nil }

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
        guard tabType == "website" else { return WakeResult(ok: true) }
        guard !session.isDestroyed else {
            return WakeResult(ok: false, message: "Tab \"\(id)\" is unavailable because it has no live WebContents.")
        }
        do {
            // Asked outside the 18s deadline below, which bounds the wake, not the wait
            // for a turn.
            try await awaitTurnToCreate(signal)
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

    /// The first part of ``wake(_:)`` alone: creates the browser tab of a tab this session
    /// opened, if it has none yet, and attaches to it, so it returns with the tab's real
    /// id known, without waiting for its page to load. A tab opened for the user needs
    /// this: nothing waits for its wake, and until its browser tab exists it has only its
    /// provisional id.
    func createInBrowser() async throws {
        try await awaitTurnToCreate(nil)
        _ = try await session.ensureAttached()
    }

    /// A tab this session opened navigates by being CREATED — `Target.createTarget`
    /// carries the url — so its one fetch never reaches `navigateToURL`, and a pacer
    /// hooked only there meters every goto while every `manage_tabs open` walks past. A
    /// tab whose real target already exists is merely being woken, nothing is fetched, and
    /// it asks for no turn.
    private func awaitTurnToCreate(_ signal: AbortSignal?) async throws {
        if session.effectiveTargetId == nil, !session.url.isEmpty {
            try await pacer?(session.url, nil, signal)
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
        // The page the agent asked this tab to load, never the address the tab was last
        // reported at: while one is asked for, a blank document is that page still on its
        // way; with none, the wait takes the current document as it is, `about:blank`
        // included. The wait ending, by seeing the page or by giving up, clears it.
        let expectedURL = session.requestedURL ?? ""
        defer { session.requestedURL = nil }

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
            // a real document, so a blank document still on its way to the
            // requested page is not reported as the tab's page.
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
    /// the pre-navigation blank/empty initial document, given the address the
    /// agent asked the tab to load (`expected`, empty when it asked for none). A
    /// tab asked for nothing, or for `about:blank`, counts a blank document as
    /// real; a tab navigating to a real URL but still showing `about:blank` does not.
    private func isRealCommittedURL(_ url: String, expected: String) -> Bool {
        if url.isEmpty { return false }
        if url == "about:blank" {
            let trimmed = expected.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed == "about:blank"
        }
        return true
    }

    public func viewportBounds() -> TabViewportBounds? {
        guard !session.isDestroyed,
              let bounds = cachedViewportBounds, bounds.width > 0, bounds.height > 0 else { return nil }
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
        session.requestedURL = url
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
        cachedViewportBounds = TabViewportBounds(width: Int(width), height: Int(height))
    }

    public func startNetworkRecording(logPath: String) {
        guard networkRecorder == nil else { return }
        // Directory first: the writer creates its file in it.
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let writer = NetworkLogWriter(path: logPath)
        let recorder = NetworkRecorder(transport: SessionScopedCDPTransport(session: session)) { record in
            writer.append(record)
        }
        networkRecorder = recorder
        Task { [session, recorder] in
            _ = try? await session.ensureAttached()
            await recorder.start()
        }
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
    /// that still lists a closed target must not let ``adoptLiveTarget`` or a listing
    /// (``syncTabsWithBrowser()``) resurrect it.
    private var closedTargetIds: Set<String> = []

    /// The owner of a tab this model counts as its own without a tool opening it: the chat
    /// the model was built for, or the user when it was built for none (`chatId` is `nil`,
    /// the default), since an attribution cannot say "a chat's tab" without a chat to name.
    private let ownChatOrUser: TabOwner

    /// Whether the tabs already open when this model seeded belong to a HUMAN. True for
    /// the user's own browser, which is what `--cdp` reaches: those tabs predate us and
    /// `manage_tabs close` refuses them. False for a browser alohajet launched, where
    /// there is no user to protect and the seeded `about:blank` is our own.
    private let seededTabsAreHuman: Bool

    private let agentOwnedTabIds: Set<String>

    /// Handed to every handle this model builds, which asks it whenever its attribution is
    /// read. See ``TabAttributionSource``.
    private let attributionSource: TabAttributionSource?

    /// Handed to every handle this model builds, so both doors a navigation leaves by are
    /// metered by the same gate. See ``NavigationPacer``.
    private let navigationPacer: NavigationPacer?

    /// Announced once per ``CDPTabHandle``, from ``register`` — the single point every
    /// creation path funnels through, so a tab cannot reach a host unannounced and end up
    /// without the host's sealed-region handling.
    private let onTabCreated: (@MainActor @Sendable (CDPTabHandle) -> Void)?

    public init(
        client: CDPClient,
        chatId: String? = nil,
        seededTabsAreHuman: Bool = true,
        agentOwnedTabIds: Set<String> = [],
        attributionSource: TabAttributionSource? = nil,
        navigationPacer: NavigationPacer? = nil,
        onTabCreated: (@MainActor @Sendable (CDPTabHandle) -> Void)? = nil
    ) {
        self.client = client
        self.ownChatOrUser = chatId.map(TabOwner.chat) ?? .user
        self.seededTabsAreHuman = seededTabsAreHuman
        self.agentOwnedTabIds = agentOwnedTabIds
        self.attributionSource = attributionSource
        self.navigationPacer = navigationPacer
        self.onTabCreated = onTabCreated
    }

    /// The route by which a tab entered this model: what ``admit(_:targetId:url:title:)``
    /// decides the tab's ownership from.
    private enum TabOrigin {
        /// Opened through ``createTab(_:)``, as `manage_tabs open` does.
        case createdByTool(TabCreateSpec)
        /// Listed by the browser when the model seeded (``seedFromBrowser()``).
        case seeded
        /// Addressed by an id the model does not track, and found among the browser's page
        /// targets (``adoptLiveTarget(_:)``).
        case adoptedLive
        /// Listed by the browser, and not yet tracked, at a listing after seeding
        /// (``syncTabsWithBrowser()``): a tab a page opened, for example.
        case foundInListing
        /// A page target missing from the snapshot passed to ``adoptSpawnedTabs(notIn:)``;
        /// outside tests, that snapshot is taken just before a click.
        case adoptedAfterClick
    }

    /// The one way a tab enters this model. Every route builds its handle here, and the
    /// tab's owner is decided here. `targetId`, `url` and `title` are whatever the route has
    /// in hand: the provisional id and requested url of a tab opened through
    /// ``createTab(_:)``, or the browser's listing of a seeded or adopted target.
    private func admit(_ origin: TabOrigin, targetId: String, url: String, title: String?) -> CDPTabHandle {
        let owner: TabOwner
        switch origin {
        case .createdByTool(let spec):
            owner = spec.owner
        case .adoptedAfterClick:
            owner = ownChatOrUser
        case .seeded, .adoptedLive, .foundInListing:
            // A tab the browser already had is the user's, except in a browser the
            // alohajet-cli program launched and for the ids it already owns.
            owner = seededTabsAreHuman && !agentOwnedTabIds.contains(targetId) ? .user : ownChatOrUser
        }
        // Only a tab opened through `createTab` is created in the browser on first attach.
        // Every other route binds to the target id it was given (no createOnAttach), so
        // attaching later reaches that target instead of creating a new one.
        let spec: TabCreateSpec? = if case .createdByTool(let spec) = origin { spec } else { nil }
        let session = CDPTabSession(
            client: client, targetId: targetId, sessionId: nil, url: url, title: title,
            createOnAttach: spec != nil)
        let handle = CDPTabHandle(
            session: session,
            tabType: spec?.tabType ?? "website",
            owner: owner,
            attributionSource: attributionSource,
            pacer: navigationPacer)
        register(handle)
        return handle
    }

    public var activeTabId: String? { _activeTabId }

    public func setActiveTabId(_ id: String?) {
        _activeTabId = id
    }

    public var tabsById: [String: TabHandle] { tabs.mapValues { $0 } }

    public var orderedTabs: [TabHandle] { order.compactMap { tabs[$0] } }

    public func tab(_ id: String) -> TabHandle? {
        resolveLocked(id)
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
        let handle = admit(.createdByTool(spec), targetId: externalId, url: spec.url, title: nil)
        // Until this page commits, the new tab's blank first document is not it.
        handle.session.requestedURL = spec.url
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
        let registeredId = forget(handle)
        closedTargetIds.insert(registeredId)
        closedTargetIds.insert(id)
        if let realTargetId = handle.session.effectiveTargetId {
            closedTargetIds.insert(realTargetId)
            _ = try? await client.send(method: "Target.closeTarget", params: ["targetId": .string(realTargetId)])
        }
    }

    /// Takes `handle` out of the list: its entry, its place in the order, and the in-use
    /// pointer if that named it. The handle is marked gone, so anything still holding it
    /// fails fast instead of reaching the browser. Sends the browser nothing. Returns the id
    /// it was registered under.
    @discardableResult
    private func forget(_ handle: CDPTabHandle) -> String {
        let registeredId = tabs.first { $0.value === handle }?.key ?? handle.id
        tabs.removeValue(forKey: registeredId)
        order.removeAll { $0 == registeredId }
        if _activeTabId == registeredId || _activeTabId == handle.id { _activeTabId = nil }
        handle.session.markDestroyed()
        return registeredId
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
        guard !seeded else { return }
        seeded = true
        guard let infos = await pageTargetInfos() else { return }
        for info in infos {
            guard let targetId = info["targetId"]?.stringValue else { continue }
            _ = admit(.seeded, targetId: targetId, url: info["url"]?.stringValue ?? "", title: info["title"]?.stringValue)
        }
    }

    /// Brings the model into line with the browser's listing, in one `Target.getTargets` for
    /// the whole window, so that the agent is told the tabs the browser has: every one it
    /// lists, none it does not, each with the address and title it lists.
    ///
    /// - A tracked tab takes the listing's address and title verbatim, `about:blank` and an
    ///   empty title included: they are the browser's latest report, and the page-load wait
    ///   reads the address the agent asked for, never this one.
    /// - A listed tab the model does not track is adopted: a tab a `target=_blank` link or a
    ///   popup opened, or one the user opened. It goes through `admit`, so whose the tab is
    ///   follows the rule for a seeded tab, and it joins the order at the end. A closed id is
    ///   skipped because `Target.closeTarget` does not wait for the tab to go.
    /// - A tracked tab the listing does not name leaves (``forget(_:)``). A tab this model
    ///   opened whose browser tab does not exist yet has no real id the listing could name,
    ///   and stays.
    public func syncTabsWithBrowser() async {
        guard let infos = await pageTargetInfos() else { return }
        var listed: Set<String> = []
        for info in infos {
            guard let targetId = info["targetId"]?.stringValue else { continue }
            listed.insert(targetId)
            let url = info["url"]?.stringValue ?? ""
            let title = info["title"]?.stringValue
            if let handle = resolveLocked(targetId) {
                handle.session.url = url
                handle.session.title = title
            } else if !closedTargetIds.contains(targetId) {
                _ = admit(.foundInListing, targetId: targetId, url: url, title: title)
            }
        }
        let gone = tabs.values.filter { handle in
            guard let realId = handle.session.effectiveTargetId else { return false }
            return !listed.contains(realId)
        }
        for handle in gone { forget(handle) }
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
    /// as the tab of the chat this model was built for, or the user's when it was built
    /// for none.
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
            let handle = admit(.adoptedAfterClick, targetId: targetId, url: url, title: info["title"]?.stringValue)
            adopted.append(AdoptedTab(id: handle.id, url: handle.url, title: handle.title))
        }
        return adopted
    }

    private func pageTargetIds() async -> Set<String> {
        guard let infos = await pageTargetInfos() else { return [] }
        return Set(infos.compactMap { $0["targetId"]?.stringValue })
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

extension CDPTabsModel: BrowserTabSyncing {}

extension CDPTabsModel: LivePageTargetAdopting {
    /// Whose the tab is follows the rule for a seeded tab, in `admit` (like
    /// ``seedFromBrowser``, unlike ``adoptSpawnedTabs``).
    public func adoptLiveTarget(_ id: String) async -> TabHandle? {
        if let existing = resolveLocked(id) { return existing }
        if closedTargetIds.contains(id) { return nil }
        guard let infos = await pageTargetInfos(),
              let info = infos.first(where: { $0["targetId"]?.stringValue == id })
        else { return nil }
        return admit(.adoptedLive, targetId: id, url: info["url"]?.stringValue ?? "", title: info["title"]?.stringValue)
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
        inFlight.count
    }

    func networkIdleForMs(threshold: Int, now: Date) -> Int {
        guard inFlight.count <= threshold else {
            idleSince = nil
            return 0
        }
        let since = idleSince ?? now
        idleSince = since
        return Int(now.timeIntervalSince(since) * 1000)
    }
}

final class DomStableTimestamp {
    private var stableAt: Date?

    func markStable() {
        if stableAt == nil { stableAt = Date() }
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
/// `expectedURL` is the address the agent asked the tab to load: when it is empty
/// (nothing asked for) or `about:blank`, a load of `about:blank` does count.
final class MainFrameLoadFlag {
    private var mainFrameId: String?
    private(set) var didLoad = false
    private(set) var committedURL: String?
    private let expectsRealURL: Bool

    init(expectedURL: String) {
        let trimmed = expectedURL.trimmingCharacters(in: .whitespaces)
        self.expectsRealURL = !trimmed.isEmpty && trimmed != "about:blank"
    }

    func setMainFrameId(_ id: String) {
        if mainFrameId == nil { mainFrameId = id }
    }

    /// Records an OBSERVED committed URL (the live document's `location.href`),
    /// without the navigation reset `Page.frameNavigated` performs — this is not a
    /// navigation, it is a reading of the document that is already there.
    func noteCommittedURL(_ url: String) {
        if !url.isEmpty { committedURL = url }
    }

    func handle(_ event: CDPEvent) {
        switch event.method {
        case "Page.frameNavigated":
            // A top-level navigation has no parentId.
            guard let frame = event.params["frame"], frame["parentId"]?.stringValue == nil else { return }
            let url = frame["url"]?.stringValue ?? ""
            if mainFrameId == nil { mainFrameId = frame["id"]?.stringValue }
            if !url.isEmpty { committedURL = url }
            // A new top-level navigation supersedes any earlier (e.g. about:blank)
            // load, so the load flag resets on navigation start.
            didLoad = false
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
        guard let main = mainFrameId, frameId == main else { return }
        // Gate on the committed URL being the real target: ignore a load of the
        // freshly-created tab's initial about:blank when a real URL is expected.
        if expectsRealURL {
            guard let url = committedURL, isRealURL(url) else { return }
        }
        didLoad = true
    }

    private func isRealURL(_ url: String) -> Bool {
        !url.isEmpty && url != "about:blank"
    }
}

final class TimeoutFlag {
    var value = false
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
        return try await group.next() ?? nil
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
/// `attributionSource`, `navigationPacer` and `onTabCreated` are the whole injection surface
/// for a host that wants more than that: the source tells the tabs model what only the
/// browser knows (see ``TabAttributionSource``), the pacer gates every navigation (see
/// ``NavigationPacer``), and `onTabCreated` hands over each ``CDPTabHandle`` the moment it
/// is registered, before anything has driven it — which is where a host installs its own
/// `domService.sealedRegionProvider`.
///
/// For tabs seeded from the browser the hook fires during this call, before the
/// `TabsService` exists. A closure that needs the service itself has nothing to capture
/// for those tabs — hang what it needs off the handle, or wire the seeded tabs from the
/// host after this returns.
///
/// `@MainActor` is spelled out although this module is main-actor by default: Swift 6.2
/// shows another module a top-level async function as nonisolated, and that module then
/// cannot hand over a main-actor `attributionSource`.
@MainActor
public func makeCDPBrowserTabsService(
    client: CDPClient,
    windowId: String = "cdp-window",
    seed: Bool = true,
    chatId: String? = nil,
    seededTabsAreHuman: Bool = true,
    agentOwnedTabIds: Set<String> = [],
    attributionSource: TabAttributionSource? = nil,
    navigationPacer: NavigationPacer? = nil,
    onTabCreated: (@MainActor @Sendable (CDPTabHandle) -> Void)? = nil
) async -> TabsService {
    let model = CDPTabsModel(
        client: client,
        chatId: chatId,
        seededTabsAreHuman: seededTabsAreHuman,
        agentOwnedTabIds: agentOwnedTabIds,
        attributionSource: attributionSource,
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
            // NOT `data.write(to:)`: that creates the log at the umask default, which is
            // the 0644 `createIfMissing` exists to prevent.
            _ = FileManager.default.createFile(
                atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
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
            members.append(("postData", .string("\(redactedValue) (\(postData.count) chars)")))
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

    static let redactedValue = "***"

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
        if sensitiveHeaderNames.contains(lowered) { return redactedValue }
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
