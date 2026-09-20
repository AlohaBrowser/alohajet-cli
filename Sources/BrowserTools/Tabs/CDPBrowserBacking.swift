import Foundation
import CDP
import ToolABI

/// The gate a navigation asks for its turn at before the page is fetched, so a host
/// that paces how fast the agent walks a site can impose one: `(url, profileId,
/// signal)`, throwing to cancel the navigation. Absent (`nil`) every turn is granted
/// immediately.
///
/// Wired once on ``CDPTabsModel`` and carried by every handle it builds, because a
/// session's navigations leave through two different doors — `Page.navigate` for a
/// goto, `Target.createTarget` for an open — and a pacer hooked to one lets the other
/// past unmetered.
///
/// `profileId` is the budget the host charges this navigation against (a per-domain
/// daily quota is the case this exists for); it is `nil` wherever the caller has none,
/// which the open path always does.
public typealias NavigationPacer = @MainActor @Sendable (String, String?, AbortSignal?) async throws -> Void

/// Converts an ordered `JSValue` object into the unordered `[String: JSValue]`
/// dictionary the CDP transport's `send` expects. Non-object values yield an
/// empty parameter set.
func cdpParams(_ value: JSValue) -> [String: JSValue] {
    guard case let .object(members) = value else { return [:] }
    return Dictionary(members, uniquingKeysWith: { _, last in last })
}

/// Tracks a single page target attached over a flat CDP session. The session is
/// the unit a ``CDPTabLayer`` / ``CDPTabDebugger`` route their commands through;
/// for a tab the agent opened the real Chrome target is created lazily.
@MainActor
final class CDPTabSession {
    nonisolated let client: CDPClient
    /// The stable external id the tab is keyed and rendered by. For an existing
    /// page target this equals the real Chrome target id; for a tab opened by
    /// the agent it is a provisional id until ``ensureAttached()`` creates the
    /// real target.
    let targetId: String
    private(set) var sessionId: String?
    /// The real Chrome target id once known (created or seeded).
    private(set) var effectiveTargetId: String?
    var url: String
    var title: String?
    private(set) var isDestroyed = false
    private var networkEnabled = false
    private var pageEnabled = false
    /// The single in-flight first-attach task. Concurrent ``ensureAttached()``
    /// callers share this so the real target is created exactly once.
    private var attachTask: Task<String, Error>?
    private let createOnAttach: Bool

    init(client: CDPClient, targetId: String, sessionId: String?, url: String, title: String? = nil, createOnAttach: Bool = false) {
        self.client = client
        self.targetId = targetId
        self.effectiveTargetId = createOnAttach ? nil : targetId
        self.sessionId = sessionId
        self.url = url
        self.title = title
        self.createOnAttach = createOnAttach
    }

    func markDestroyed() {
        isDestroyed = true
    }

    /// Ensures the underlying Chrome target exists (creating it for an
    /// agent-opened tab) and is attached over a flat session, returning the
    /// session id.
    func ensureAttached() async throws -> String {
        if let sessionId, !isDestroyed {
            return sessionId
        }
        guard !isDestroyed else { throw CDPError.notConnected }
        // Coalesce concurrent first-attach callers onto ONE in-flight task. Without
        // this, two callers (e.g. the network-recording enable and the focus/load
        // read) both pass the `sessionId == nil` check, both release the lock
        // across the `await`, and each issues `Target.createTarget` — opening the
        // tab twice. Sharing one task creates the target exactly once.
        if let attachTask {
            return try await attachTask.value
        }
        let task = Task { try await self.performAttach() }
        attachTask = task
        defer { if attachTask == task { attachTask = nil } }
        return try await task.value
    }

    /// Creates the real Chrome target (for an agent-opened tab) when none exists
    /// yet and attaches a flat session. Runs inside the single in-flight task held
    /// by ``ensureAttached()`` so the create happens once under concurrent callers.
    private func performAttach() async throws -> String {
        guard !isDestroyed else { throw CDPError.notConnected }
        if effectiveTargetId == nil {
            effectiveTargetId = try await client.openTab(url: url)
        }
        guard let resolved = effectiveTargetId else { throw CDPError.notConnected }
        let session = try await client.attachToTarget(targetId: resolved)
        sessionId = session
        return session
    }

    /// Enables the `Page` domain once for screenshots / lifecycle reads.
    func ensurePageEnabled() async throws {
        let session = try await ensureAttached()
        guard !pageEnabled else { return }
        _ = try? await client.send(method: "Page.enable", params: [:], sessionId: session)
        pageEnabled = true
    }

    /// Enables the `Network` domain once for traffic recording. Returns whether
    /// this call performed the enable (so the caller can attach listeners once).
    @discardableResult
    func ensureNetworkEnabled() async throws -> Bool {
        let session = try await ensureAttached()
        guard !networkEnabled else { return false }
        _ = try? await client.send(method: "Network.enable", params: [:], sessionId: session)
        networkEnabled = true
        return true
    }
}

/// A ``CDPTransport`` scoped to a single tab's flat CDP session: every command is
/// sent with the tab's session id (so domains like `Network` enable on the page,
/// not the root browser connection), and the event stream is filtered to that
/// session — letting a session-agnostic consumer like ``NetworkRecorder`` drive
/// one specific tab.
final class SessionScopedCDPTransport: CDPTransport {
    private let session: CDPTabSession

    nonisolated init(session: CDPTabSession) { self.session = session }

    func connect() async throws {}

    func send(method: String, params: [String: JSValue]) async throws -> JSValue {
        let sessionId = try await session.ensureAttached()
        return try await session.client.send(method: method, params: params, sessionId: sessionId)
    }

    func events() -> AsyncStream<CDPEvent> {
        let session = self.session
        return AsyncStream { continuation in
            let task = Task {
                for await event in session.client.events() {
                    let scoped = await session.sessionId
                    if event.sessionId == nil || event.sessionId == scoped {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Subscribes to `Runtime.consoleAPICalled` on a tab's flat CDP session and
/// accumulates up to 50 ``ConsoleCapture`` entries while active. Only the three
/// levels `log` / `warn` / `error` are recorded.
final class ConsoleCaptureSession {
    private var entries: [ConsoleCapture] = []
    private var forwarder: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var continuation: AsyncStream<JSValue>.Continuation?
    private var endSubscription: (@Sendable () async -> Void)?

    static let maxEntries = 50

    /// Begins consuming events from a pre-registered CDP event stream. A
    /// forwarder task copies matching `Runtime.consoleAPICalled` payloads
    /// (filtered to `sessionId`, fixed for the capture and so read once here
    /// rather than per event) into an owned stream; a consumer task drains that
    /// stream and records each entry. Splitting the two lets ``stop()`` finish the
    /// owned stream and await the consumer, draining every buffered payload
    /// deterministically. The caller passes a stream obtained via
    /// `CDPClient.subscribeEvents(id:)` so no early event is missed, and
    /// `endSubscription` ends that same subscription — the only way to drain it to
    /// completion instead of hoping a settle delay was long enough.
    func start(events: AsyncStream<CDPEvent>,
               sessionId: String?,
               endSubscription: @escaping @Sendable () async -> Void) {
        self.endSubscription = endSubscription
        let (stream, continuation) = AsyncStream<JSValue>.makeStream()
        self.continuation = continuation
        consumer = Task { [weak self] in
            for await params in stream {
                guard let self else { break }
                self.record(params)
            }
        }
        forwarder = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { break }
                guard event.sessionId == nil || event.sessionId == sessionId else { continue }
                guard event.method == "Runtime.consoleAPICalled" else { continue }
                guard self != nil else { break }
                continuation.yield(event.params)
            }
        }
    }

    /// Drains and ends the capture, returning the accumulated entries.
    ///
    /// Ending the client subscription finishes the event stream after everything
    /// already dispatched into it (the caller issues a CDP barrier round-trip first,
    /// so those deliveries have happened), so awaiting the forwarder drains every one
    /// of them into the owned stream; that stream is then finished and the consumer
    /// awaited, which delivers all buffered payloads before completing — so the
    /// recorded set is exact, with nothing riding on how fast the machine is.
    func stop() async -> [ConsoleCapture] {
        await endSubscription?()
        endSubscription = nil
        await forwarder?.value
        forwarder = nil
        continuation?.finish()
        continuation = nil
        await consumer?.value
        consumer = nil
        return entries
    }

    private func record(_ params: JSValue) {
        guard entries.count < Self.maxEntries else { return }
        entries.append(ConsoleCapture(
            level: Self.mapConsoleLevel(params["type"]?.stringValue),
            msg: Self.renderArgs(params["args"])))
    }

    private static func mapConsoleLevel(_ type: String?) -> String {
        switch type {
        case "warning": "warn"
        case "error", "assert": "error"
        default: "log"
        }
    }

    private static func renderArgs(_ args: JSValue?) -> String {
        guard let array = args?.arrayValue else { return "" }
        let pieces: [String] = array.map { arg in
            if let value = arg["value"] {
                switch value {
                case let .string(text): return text
                case let .number(number):
                    if number == number.rounded() && abs(number) < 1e15 { return String(Int64(number)) }
                    return String(number)
                case let .bool(flag): return flag ? "true" : "false"
                case .null: return "null"
                case .undefined: return "undefined"
                case .array, .object:
                    return arg["description"]?.stringValue ?? ""
                }
            }
            if let description = arg["description"]?.stringValue { return description }
            return arg["type"]?.stringValue ?? ""
        }
        return pieces.joined(separator: " ")
    }
}

/// A ``TabLayer`` that evaluates page-side scripts over a tab's flat CDP session
/// using `Runtime.evaluate`.
@MainActor
final class CDPTabLayer: TabLayer {
    nonisolated let session: CDPTabSession

    nonisolated init(session: CDPTabSession) {
        self.session = session
    }

    nonisolated func executeJavaScript(_ script: String) async throws -> JSValue {
        try await withCDPDeadline(milliseconds: 15_000) {
            let sessionId = try await self.session.ensureAttached()
            let result = try await self.session.client.send(
                method: "Runtime.evaluate",
                params: [
                    "expression": .string(script),
                    "returnByValue": .bool(true),
                    "awaitPromise": .bool(true),
                    "userGesture": .bool(true)
                ],
                sessionId: sessionId
            )
            if let exception = result["exceptionDetails"], case .object = exception {
                let text = exception["exception"]?["description"]?.stringValue
                    ?? exception["text"]?.stringValue
                    ?? "Runtime.evaluate threw"
                throw SimpleBrowserError(text)
            }
            if let object = result["result"], case .object = object {
                if let value = object["value"] { return value }
                return .undefined
            }
            return .undefined
        }
    }

    // `TabLayer` requires a `nonisolated` synchronous read. The destroyed flag is
    // main-isolated; rather than expose it nonisolated, this fast-path read reports
    // "live" and the async paths (`ensureAttached`) throw `notConnected` for a
    // destroyed session, so a destroyed tab's operations still fail.
    nonisolated func isDestroyed() -> Bool {
        false
    }
}

/// A ``TabDebugger`` that routes raw CDP commands and synthetic input to a tab's
/// flat session. `simulateMouseClick` dispatches a mousePressed + mouseReleased
/// pair carrying `clickCount`.
@MainActor
final class CDPTabDebugger: TabDebugger {
    nonisolated let session: CDPTabSession

    nonisolated init(session: CDPTabSession) {
        self.session = session
    }

    nonisolated func simulateMouseClick(_ x: Int, _ y: Int, _ button: String, _ count: Int, _ signal: AbortSignal?) async throws {
        if (await signal?.aborted) == true { throw SimpleBrowserError("Operation aborted") }
        let sessionId = try await session.ensureAttached()
        let buttonsMask: Int = switch button {
        case "right": 2
        case "middle": 4
        default: 1
        }
        let pressed: [String: JSValue] = [
            "type": .string("mousePressed"),
            "x": .number(Double(x)),
            "y": .number(Double(y)),
            "button": .string(button),
            "buttons": .number(buttonsMask),
            "clickCount": .number(count)
        ]
        _ = try await session.client.send(method: "Input.dispatchMouseEvent", params: pressed, sessionId: sessionId)
        if (await signal?.aborted) == true { throw SimpleBrowserError("Operation aborted") }
        let released: [String: JSValue] = [
            "type": .string("mouseReleased"),
            "x": .number(Double(x)),
            "y": .number(Double(y)),
            "button": .string(button),
            "buttons": .number(0),
            "clickCount": .number(count)
        ]
        _ = try await session.client.send(method: "Input.dispatchMouseEvent", params: released, sessionId: sessionId)
    }

    @discardableResult
    func sendCommand(_ domain: String, _ method: String, _ params: JSValue) async throws -> JSValue {
        let sessionId = try await session.ensureAttached()
        return try await session.client.send(method: "\(domain).\(method)", params: cdpParams(params), sessionId: sessionId)
    }
}

/// Builds a ``CDPTabDebugger`` for the session backing a CDP browser tab. A
/// non-CDP tab yields a debugger whose commands fail (the CDP backing only ever
/// hands it ``CDPBrowserTab`` values).
nonisolated struct CDPTabDebuggerFactory: TabDebuggerFactory {
    func makeDebugger(_ tab: BrowserTab) -> TabDebugger {
        if let cdpTab = tab as? CDPBrowserTab {
            return CDPTabDebugger(session: cdpTab.session)
        }
        return NoopTabDebugger()
    }
}

nonisolated struct NoopTabDebugger: TabDebugger {
    func simulateMouseClick(_ x: Int, _ y: Int, _ button: String, _ count: Int, _ signal: AbortSignal?) async throws {
        throw SimpleBrowserError("No CDP debugger for this tab")
    }
    @discardableResult
    func sendCommand(_ domain: String, _ method: String, _ params: JSValue) async throws -> JSValue {
        throw SimpleBrowserError("No CDP debugger for this tab")
    }
}

/// A ``BrowserTab`` backed by a flat CDP page session. Screenshots use
/// `Page.captureScreenshot`; the agent mouse position is tracked in-process and
/// reflected to the page by the cursor animator.
@MainActor
final class CDPBrowserTab: BrowserTab {
    nonisolated let session: CDPTabSession
    nonisolated let cdpLayer: CDPTabLayer

    nonisolated init(session: CDPTabSession) {
        self.session = session
        self.cdpLayer = CDPTabLayer(session: session)
    }

    nonisolated var id: String { session.targetId }
    nonisolated var layer: TabLayer { cdpLayer }
    nonisolated func getLayer() -> TabLayer { cdpLayer }

    // The `BrowserTab` protocol requires a `nonisolated` SYNCHRONOUS read, and where the
    // agent left its pointer lives in the page (`window.__alohaAgentCursor`), which can
    // only be read asynchronously — so this conformance has nothing to report.
    //
    // The animation does not depend on it: the page-side script reads that global itself.
    // What is left unserved is `AgentDOMService.clickAtCurrentCursorPosition`, which
    // refuses on a CDP tab for want of an answer here. Serving it needs an async read on
    // the protocol, not a coordinate cached in this process — a cached one would go on
    // naming a place on a page that has since been replaced.
    nonisolated func getAgentMousePosition() -> AgentMousePosition? {
        nil
    }

    nonisolated func waitForNextAnimationFrames(_ count: Int) async throws {
        let frames = max(1, count)
        let script = """
        new Promise(resolve => {
          let remaining = \(frames);
          function step() {
            remaining -= 1;
            if (remaining <= 0) { resolve(true); return; }
            requestAnimationFrame(step);
          }
          requestAnimationFrame(step);
        })
        """
        // Bound the rAF wait at 5s and swallow the timeout.
        // `requestAnimationFrame` is throttled/coalesced in a freshly-opened
        // BACKGROUND tab, so this eval can otherwise stall for the whole read; a
        // settle frame is best-effort, never a reason to block.
        try? await withCDPDeadline(milliseconds: 5_000) {
            _ = try? await self.cdpLayer.executeJavaScript(script)
        }
    }

    /// First try a short capture. A background tab has no compositor surface, so
    /// `fromSurface: true` hangs. `Page.bringToFront` then one retry is the
    /// measured recovery; a tab that is already frontmost never reaches it.
    private nonisolated func captureWakingSurfaceIfNeeded(
        params: [String: JSValue], sessionId: String
    ) async throws -> JSValue {
        let first = try? await withCDPDeadline(milliseconds: 2_500) {
            try await self.session.client.send(method: "Page.captureScreenshot", params: params,
                                               sessionId: sessionId)
        }
        if let first, let data = first["data"]?.stringValue, !data.isEmpty {
            return first
        }
        // BEST-EFFORT ON THE RESPONSE, NEVER ON BROWSER IDENTITY — see the same call in
        // CDPTabsService.wake(). An endpoint without the method answers `-32601 Method
        // not found`; `try?` drops that and the retry below still runs, because the
        // retry is what produces the bytes and bringToFront only makes it faster on
        // Chromium. Never gate this on "which browser is this": the package cannot tell,
        // and the workaround is for a Chromium behaviour, not for a browser's identity.
        _ = try? await withCDPDeadline(milliseconds: 2_000) {
            try await self.session.client.send(method: "Page.bringToFront", params: [:],
                                               sessionId: sessionId)
        }
        return try await withCDPDeadline(milliseconds: 10_000) {
            try await self.session.client.send(method: "Page.captureScreenshot", params: params,
                                               sessionId: sessionId)
        }
    }

    nonisolated func getViewportBase64() async throws -> String? {
        guard let metadata = try await getViewportBase64WithMetadata(nil, 1) else { return nil }
        return metadata.base64
    }

    nonisolated func getViewportBase64WithMetadata(_ format: String?, _ scale: Double) async throws -> ViewportCaptureMetadata? {
        try await session.ensurePageEnabled()
        let sessionId = try await session.ensureAttached()
        let imageFormat = (format == "png") ? "png" : "jpeg"
        var params: [String: JSValue] = [
            "format": .string(imageFormat),
            "captureBeyondViewport": .bool(false),
            "fromSurface": .bool(true)
        ]
        if imageFormat == "jpeg" {
            params["quality"] = .number(80)
        }
        // A BACKGROUND tab has no compositor surface, so `fromSurface: true` can
        // hang until the deadline. Short first attempt, then `Page.bringToFront`
        // and one retry — measured >20s hang became 163ms once the tab was
        // composited. Markdown is still returned if both attempts fail.
        let result = try await captureWakingSurfaceIfNeeded(params: params, sessionId: sessionId)
        guard let data = result["data"]?.stringValue, !data.isEmpty else { return nil }
        let mime = imageFormat == "png" ? "image/png" : "image/jpeg"
        let dataUrl = "data:\(mime);base64,\(data)"
        let metrics = try? await session.client.send(method: "Page.getLayoutMetrics", params: [:], sessionId: sessionId)
        let viewport = metrics?["cssLayoutViewport"]
        let width = viewport?["clientWidth"]?.doubleValue ?? 0
        let height = viewport?["clientHeight"]?.doubleValue ?? 0
        return ViewportCaptureMetadata(base64: dataUrl, imageWidth: Int(width), imageHeight: Int(height))
    }
}

/// Animates an arrow cursor toward a target and performs a press flourish in the
/// page, then dispatches a real `Input.dispatchMouseEvent` `mouseMoved`. Any
/// failure is swallowed so a missing animation never blocks the click.
nonisolated struct CDPAgentCursorAnimator: AgentCursorAnimator {
    func animateAgentCursorClick(_ tab: BrowserTab, _ bounds: ElementBounds, _ label: String, scaleOnClick: Bool, cursorLabelKind: String?) async {
        guard let cdpTab = tab as? CDPBrowserTab else { return }
        let targetX = Int((bounds.x + bounds.width / 2).rounded())
        let targetY = Int((bounds.y + bounds.height / 2).rounded())
        // The flourish is cosmetic and costs up to 600ms of every click, so it is
        // skipped outright when nobody is watching (`ALOHAJET_HIGHLIGHTS=0`). The
        // real `mouseMoved` below is dispatched either way — the page sees the
        // same click sequence with the paint on or off.
        if AgentCursorAppearance.animationEnabled {
            agentLog(.info, "[viz] cursor → (\(targetX),\(targetY)) label=\"\(label)\" scaleOnClick=\(scaleOnClick)")
            let color = AgentCursorAppearance.fillHex
            // No start point is passed. Where the pointer was left is a fact about the
            // DOCUMENT, so the script reads it from the page it is about to draw on —
            // this process cannot hold it without also holding a coordinate on a page
            // that may already be gone.
            let script = buildAgentCursorClickScript(
                targetX: targetX,
                targetY: targetY,
                color: color,
                scaleOnClick: scaleOnClick
            )
            let timeoutMs = scaleOnClick ? 600 : 200
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { _ = try await cdpTab.getLayer().executeJavaScript(script) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                        throw SimpleBrowserError("Mouse movement animation timed out")
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {}
        }
        let debuggerInstance = CDPTabDebugger(session: cdpTab.session)
        _ = try? await debuggerInstance.sendCommand("Input", "dispatchMouseEvent", .object([
            ("type", .string("mouseMoved")),
            ("x", .number(Double(targetX))),
            ("y", .number(Double(targetY)))
        ]))
    }
}

nonisolated struct CDPDomTreeScriptProvider: DomTreeScriptProvider {
    func buildDomTreeScript(highlight: Bool, focusInteractive: Bool) -> String {
        buildAgentDomTreeScript(highlight: highlight, focusInteractive: focusInteractive)
    }
}

/// An ``AgentBridgeBackend`` that drives a single ``CDPTabHandle`` over its flat
/// CDP session. It carries the navigation seam (rate-limited `Page.navigate`,
/// history-back, page-readiness waits), routes raw input/evaluate commands
/// through the tab debugger, animates the agent cursor, and terminates an
/// in-flight evaluation on abort — making the bridge usable against a real
/// browser without any hand-written per-platform glue.
public final class CDPAgentBridgeBackend: AgentBridgeBackend {
    private let handle: CDPTabHandle
    private let signal: AbortSignal?
    private let cursorAnimator: AgentCursorAnimator

    public init(
        tab: CDPTabHandle,
        signal: AbortSignal? = nil
    ) {
        self.handle = tab
        self.signal = signal
        self.cursorAnimator = CDPAgentCursorAnimator()
    }

    private var debuggerInstance: CDPTabDebugger { CDPTabDebugger(session: handle.session) }

    public func consumeAgentDownloads() -> [CapturedDownload] { [] }

    public var isAborted: Bool { signal?.aborted == true }

    /// No human hand-off surface exists in this package: a CLI / MCP server has no
    /// window to put in front of the person at the keyboard.
    public func handOffCaptchaToHuman() async -> Bool { false }

    public func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        if isAborted {
            await terminateExecution()
            throw AgentAbortError()
        }
        await ensureFocusEmulation()
        do {
            let result = try await debuggerInstance.sendCommand("Runtime", "evaluate", .object([
                ("expression", .string(expression)),
                ("awaitPromise", .bool(true)),
                ("returnByValue", .bool(true)),
                ("userGesture", .bool(true))
            ]))
            if let details = result["exceptionDetails"], case .object = details {
                let message = details["exception"]?["description"]?.stringValue
                    ?? details["text"]?.stringValue
                    ?? details["exception"]?["value"]?.stringValue
                    ?? "CDP evaluation error"
                throw SimpleBrowserError(message)
            }
            if isAborted {
                await terminateExecution()
                throw AgentAbortError()
            }
            return result["result"]?["value"]
        } catch {
            if isAborted {
                await terminateExecution()
                throw AgentAbortError()
            }
            throw error
        }
    }

    private var focusEmulationEnabled = false

    /// Tells the renderer to treat this frame as focused, once per backend. On a
    /// headless or background CDP tab the page frame is not the OS-focused frame,
    /// so synthetic `Input` key events reach the focused element (typing works)
    /// but their default actions — most notably Enter submitting a form — are
    /// dropped. Enabling `Emulation.setFocusEmulationEnabled` restores those
    /// default actions; on an already-focused real window it is a harmless no-op.
    private func ensureFocusEmulation() async {
        let already = focusEmulationEnabled
        focusEmulationEnabled = true
        if already { return }
        _ = try? await debuggerInstance.sendCommand("Emulation", "setFocusEmulationEnabled", .object([("enabled", .bool(true))]))
    }

    @discardableResult
    public func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue {
        if isAborted { throw AgentAbortError() }
        if domain == "Input" { await ensureFocusEmulation() }
        let result = try await debuggerInstance.sendCommand(domain, command, .object(params.map { ($0.key, $0.value) }))
        if isAborted { throw AgentAbortError() }
        return result
    }

    /// Routes a raw command to a named CDP session on the same connection.
    ///
    /// `.page` is the tab's own session and behaves exactly as the unaddressed call
    /// above. `.attached` carries a flat session id from
    /// `Target.attachToTarget{flatten: true}` — an out-of-process frame's own
    /// renderer session — which rides the same websocket, tagged with that id.
    /// Focus emulation is a page-level concern, so it is enabled for the tab's
    /// session regardless of which session the command itself is addressed to.
    @discardableResult
    public func sendCdpCommand(
        domain: String, command: String, params: [String: JSValue], on target: CDPSessionTarget
    ) async throws -> JSValue {
        guard case .attached(let sessionId) = target else {
            return try await sendCdpCommand(domain: domain, command: command, params: params)
        }
        if isAborted { throw AgentAbortError() }
        if domain == "Input" { await ensureFocusEmulation() }
        let result = try await handle.session.client.send(
            method: "\(domain).\(command)", params: params, sessionId: sessionId)
        if isAborted { throw AgentAbortError() }
        return result
    }

    // MARK: Console capture

    private var consoleCapture: ConsoleCaptureSession?

    /// Enables the `Runtime` domain and subscribes to `Runtime.consoleAPICalled`
    /// on this tab's session, accumulating up to 50 entries until capture ends.
    public func beginConsoleCapture() async {
        let session = handle.session
        let sessionId: String
        do {
            sessionId = try await session.ensureAttached()
        } catch {
            return
        }
        // Register the event subscription before enabling the domain so no
        // `Runtime.consoleAPICalled` emitted after enable can race ahead of it.
        let subscription = UUID()
        let events = await session.client.subscribeEvents(id: subscription)
        _ = try? await session.client.send(method: "Runtime.enable", params: [:], sessionId: sessionId)
        let capture = ConsoleCaptureSession()
        consoleCapture = capture
        let client = session.client
        capture.start(events: events, sessionId: sessionId) {
            await client.endEventSubscription(subscription)
        }
    }

    /// Stops the active console capture and returns the accumulated entries.
    ///
    /// A `Runtime.evaluate` barrier round-trip is issued first: by CDP's in-order
    /// delivery, once its response returns every `Runtime.consoleAPICalled` event
    /// the page emitted during the run has already been dispatched to the capture
    /// subscription, so the subsequent drain observes them all.
    public func endConsoleCapture() async -> [ConsoleCapture] {
        let capture = consoleCapture
        consoleCapture = nil
        guard let capture else { return [] }
        let session = handle.session
        if let sessionId = try? await session.ensureAttached() {
            _ = try? await session.client.send(
                method: "Runtime.evaluate",
                params: ["expression": .string("0")],
                sessionId: sessionId)
        }
        return await capture.stop()
    }

    public func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? {
        guard let metadata = try await handle.browserTab.getViewportBase64WithMetadata(nil, 1) else { return nil }
        return (stripDataUrlPrefix(metadata.base64), metadata.imageWidth, metadata.imageHeight)
    }

    public func viewportDimensions() -> ViewportSize? {
        guard let bounds = handle.viewportBounds() else { return nil }
        return ViewportSize(width: bounds.width, height: bounds.height)
    }

    public func resolveSandboxSavePath(_ path: String) -> String? { nil }

    public func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}

    // MARK: Navigation seam

    public func currentURL() -> String { handle.url }

    public func noteCurrentURL(_ url: String) { handle.noteObservedURL(url) }

    public func navigate(url: String, profileId: String?, options: NavigationReadinessOptions) async throws {
        if isAborted { throw AgentAbortError() }
        // The pacer lives on the handle, not here: the open path navigates without ever
        // building a backing, so a gate held at this level would meter half the traffic.
        try await handle.navigateToURL(url, profileId: profileId, signal: signal)
        try await awaitReady(options)
    }

    public func goBack(options: NavigationReadinessOptions) async throws {
        if isAborted { throw AgentAbortError() }
        try await handle.goBackHistory(signal: signal)
        try await awaitReady(options)
    }

    private func awaitReady(_ options: NavigationReadinessOptions) async throws {
        if isAborted { throw AgentAbortError() }
        let result = await handle.waitForReady(
            PageReadinessOptions(
                networkIdleThreshold: options.networkIdleThreshold,
                networkIdleTimeMs: options.networkIdleTimeMs,
                domStableTimeMs: options.domStableTimeMs,
                minWaitTimeMs: options.minWaitTimeMs,
                timeoutMs: options.timeoutMs),
            signal: signal)
        if result.reason == .aborted { throw AgentAbortError() }
    }

    public func animateCursorTo(x: Double, y: Double) async {
        let bounds = ElementBounds(
            x: x, y: y, width: 0, height: 0,
            top: y, right: x, bottom: y, left: x)
        await cursorAnimator.animateAgentCursorClick(handle.browserTab, bounds, "", scaleOnClick: false, cursorLabelKind: nil)
    }

    public func terminateExecution() async {
        _ = try? await debuggerInstance.sendCommand("Runtime", "terminateExecution", .object([]))
    }
}

nonisolated struct SimpleBrowserError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Runs `operation`, throwing ``SimpleBrowserError`` if it does not finish within
/// `milliseconds`. The hung operation is cancelled and **abandoned**.
///
/// A `TaskGroup` cannot be used here: group exit waits for cancelled children, and
/// a hung CDP send (`Runtime.evaluate` / `Page.captureScreenshot` against a tab
/// with no compositor) ignores cancellation. The previous TaskGroup bound therefore
/// never returned — measured after `manage_tabs open`, the page already in `/json`,
/// no next tool call for 130s+. This module defaults to MainActor,
/// which made the timer share the same executor as the hung op.
///
/// `nonisolated` so the timer is not MainActor. Resume-once so the deadline and
/// the operation cannot double-resume the continuation.
nonisolated func withCDPDeadline<T: Sendable>(
    milliseconds: Double,
    _ operation: @escaping @MainActor @Sendable () async throws -> T
) async throws -> T {
    let gate = DeadlineResumeGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            gate.bind(cont)
            let op = Task {
                do {
                    gate.finish(.success(try await operation()))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(milliseconds * 1_000_000))
                if Task.isCancelled { return }
                gate.finish(.failure(SimpleBrowserError(
                    "operation exceeded deadline after \(Int(milliseconds))ms")))
            }
            gate.attach(op: op, timer: timer)
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// Resume-once box so the deadline and the operation cannot double-resume.
/// Cancels the timer when the op wins so a cancelled caller is not parked on
/// the remaining sleep (up to 20s).
private nonisolated final class DeadlineResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var op: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    func bind(_ cont: CheckedContinuation<T, Error>) {
        lock.lock()
        self.cont = cont
        lock.unlock()
    }
    func attach(op: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        self.op = op
        self.timer = timer
        lock.unlock()
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let taken = cont
        cont = nil
        let t = timer
        timer = nil
        let o = op
        op = nil
        lock.unlock()
        t?.cancel()
        o?.cancel()
        taken?.resume(with: result)
    }
}
