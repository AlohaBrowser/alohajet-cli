import Foundation
import ToolABI
import CDP

// MARK: - MockCDP

/// A scriptable, stateful fake Chrome that speaks raw CDP JSON-RPC frames over a
/// ``CDPMessageChannel``. A `CDPClient(channel:)` built on it runs the real
/// JSON-RPC correlation, flat-session routing, receive loop, and event fan-out —
/// so the whole tabs-service graph (``makeCDPBrowserTabsService``) drives this
/// fake browser exactly as it would a real one.
///
/// It maintains fake page targets + per-target attached sessions + a tiny DOM
/// (the `document.body.innerText` `Runtime.evaluate` reads), responds to the
/// target/runtime/page/input/network commands the runtime issues, and RECORDS
/// every command for assertions. Unknown commands get an empty `{}` result so an
/// unexpected call never deadlocks a turn.
@MainActor
final class MockCDP {
    /// One recorded command the fake browser received.
    struct Command: Sendable, Equatable {
        let method: String
        let params: JSValue
        let sessionId: String?
    }

    private var commands: [Command] = []
    private var targets: [String: FakeTarget] = [:]
    private var sessionToTarget: [String: String] = [:]
    private var nextTargetSeq = 0
    private var nextSessionSeq = 0

    /// Pushes an unsolicited frame into the live channel's inbox. Set when a
    /// ``MockCDPChannel`` is created so a test can emit server-initiated CDP
    /// events (which have a `method` but no `id`).
    private var eventSink: (@Sendable (String) -> Void)?

    /// The most recently attached session id, used as the default for emitted
    /// events so they pass a session-scoped consumer's filter.
    private var lastSessionId: String?

    /// The fake DOM text every tab's `document.body.innerText` evaluation returns.
    var bodyText = "Example Domain"

    /// What the focused field would hold after the keystrokes this mock has been handed.
    ///
    /// The `type` path RE-READS the field before it reports success — `ensureValueLanded`
    /// in PageBridge.swift — and returns an error when the read does not
    /// show the typed text ("Typing into X did NOT take: the field still reads …"). Nothing
    /// here modelled that, so the read fell through to `bodyText` and every typing test
    /// failed with the page title as the field's value, whatever the type path had done.
    /// Accumulated from the two commands that put characters in a field: per-keystroke
    /// `Input.dispatchKeyEvent` for ASCII and `Input.insertText` for the rest.
    private(set) var typedValue = ""

    /// The url/title the wake-path `document.readyState` probe reports for the
    /// fake page (kept stable so a real wake settles immediately).
    var pageUrl = "https://example.com"
    var pageTitle = "Example Domain"

    /// A scriptable navigation history for the history-back path: the entry urls
    /// and the index the fake page currently sits at. When `back` targets a prior
    /// entry the probe url advances to it so a real `goBack` reports the new url.
    var navigationHistory: [String] = ["https://example.com/first", "https://example.com/second"]
    var navigationIndex = 1

    /// A scripted reply for the agent-code runner wrapper (`buildAgentCodeRunnerScript`):
    /// when a `Runtime.evaluate` expression carries the wrapper's `__alohaPending`
    /// marker, the fake page returns this `{ result, error, pending }` object
    /// instead of the plain body text — letting a composition test drive the
    /// wired `tab_execute` → `executeAgentCode` → pending-drain path. `nil` keeps
    /// the default string-body behaviour.
    var agentRunnerPendingReply: JSValue?

    /// Console events the fake page emits while the agent-code runner is being
    /// evaluated (i.e. during `executeAgentCode`'s capture window), mirroring a
    /// page whose `console.log`/`warn`/`error` fire as the script runs. Each
    /// entry is a `(type, message)` pair fed to ``emitConsoleAPICalled``.
    var consoleEventsOnAgentEval: [(type: String, message: String)] = []

    /// Scripted cookies the fake browser returns for `Network.getCookies` — the
    /// tab cookies a composition test wants forwarded as a `Cookie` header. Each
    /// entry is a `(name, value)` pair.
    var cookies: [(name: String, value: String)] = []

    /// The base64 payload returned for `Page.captureScreenshot`. Defaults to an
    /// empty string (capture is recorded but yields no bytes); a non-empty value
    /// lets a screenshot flow settle with real bytes.
    var screenshotData = ""

    /// Remaining `Page.captureScreenshot` calls that fail with a CDP error (no
    /// compositor surface). Pins the bringToFront retry.
    var screenshotFailRemaining = 0

    /// Remaining captures that succeed with empty `data` (no throw). Production
    /// retries those behind `Page.bringToFront` the same as a thrown failure.
    var screenshotEmptyRemaining = 0

    /// Methods this fake endpoint does NOT implement: each is answered `-32601 Method
    /// not found`, the way a CDP server replies to a command outside its surface. Models
    /// the Aloha browser, whose own CDP server implements every method this package sends
    /// except `Page.bringToFront` — the recovery must survive that answer, and the
    /// survival has to be pinned on the RESPONSE, since nothing here says who the browser
    /// is and nothing in production may ask.
    var methodsNotImplemented: Set<String> = []

    /// When true, `Runtime.evaluate` is left unanswered until a `Page.navigate`
    /// has been seen. Models Aloha's frozen default-tab WKWebView, which hangs
    /// eval until a real navigation revives the renderer.
    var suppressEvaluateUntilNavigate = false
    private var didNavigate = false

    /// A scripted DOM-tree reply for the agent-interactive-markdown walker
    /// (`buildAgentDomTreeScript`): when a `Runtime.evaluate` expression is that
    /// walker script (recognized by its `buildDomTree(` call), the fake page
    /// returns this array of raw DOM-node JSON objects — the same shape
    /// `parseDomNode` consumes — instead of falling through to the plain
    /// `bodyText` catch-all. `nil` (the default) keeps that catch-all behavior,
    /// which `AgentDOMService.getDOM` treats as zero DOM nodes (no error).
    var domTreeReply: [JSValue]?

    /// Scripted replies for RAW (non-`buildAgentCodeRunnerScript`-wrapped)
    /// `window.__aloha.<verb>(...)` evaluate calls — the transport
    /// `AgentBrowserBridge.selectOptionById` / `.getTextById` / `.waitForSelector`
    /// issue directly (see PageBridge.swift's "select / getText / waitFor" MARK):
    /// no `enqueueCdp` round trip, so no `__alohaPending` marker to recognize.
    /// Each entry is `(substring to match in the expression, reply value)`; the
    /// first match wins. Empty (the default) keeps every such call falling through
    /// to the plain `bodyText` catch-all below.
    var alohaRawCallReplies: [(match: String, reply: JSValue)] = []

    private struct FakeTarget {
        var targetId: String
        var url: String
        var title: String
        var type: String
    }

    init() {}

    // MARK: Scripted targets

    /// Registers a page (or other-typed) target the fake browser reports from
    /// `Target.getTargets`, mirroring a tab that already exists or that a click
    /// spawned. Used to drive the click-spawned tab adoption path.
    func addTarget(id: String, url: String, title: String = "", type: String = "page") {
        targets[id] = FakeTarget(targetId: id, url: url, title: title, type: type)
    }

    // MARK: Channel

    /// A ``CDPMessageChannel`` view of this fake browser to hand `CDPClient`.
    func channel() -> CDPMessageChannel {
        let channel = MockCDPChannel(browser: self)
        // Synchronous, so back-to-back emissions keep their order. Spawning a Task per
        // frame here would race them into the channel actor, which has no FIFO
        // guarantee — see MockCDPChannel's ordering note.
        eventSink = { [weak channel] frame in channel?.inject(frame) }
        return channel
    }

    // MARK: Event injection

    /// The default session id emitted events are tagged with: the most recently
    /// attached session, so a session-scoped consumer accepts them.
    func currentSessionId() -> String? { lastSessionId }

    /// Emits an unsolicited CDP event frame (a JSON-RPC message with a `method`
    /// but no `id`), routed through the live channel into the client's receive
    /// loop. When `sessionId` is omitted the most recently attached session is
    /// used.
    func emitEvent(method: String, params: JSValue, sessionId: String? = nil) {
        let (sink, defaultSid) = (eventSink, lastSessionId)
        let frame = JSValue.object([
            ("method", .string(method)),
            ("params", params),
            ("sessionId", (sessionId ?? defaultSid).map { JSValue.string($0) } ?? .null)
        ])
        sink?(frame.stringify())
    }

    /// Emits a `Runtime.consoleAPICalled` event with the given `type` and a
    /// single string argument, mirroring what Chrome sends for `console.log`.
    func emitConsoleAPICalled(type: String, message: String, sessionId: String? = nil) {
        emitEvent(method: "Runtime.consoleAPICalled", params: .object([
            ("type", .string(type)),
            ("args", .array([.object([
                ("type", .string("string")),
                ("value", .string(message))
            ])]))
        ]), sessionId: sessionId)
    }

    // MARK: Recorded-command assertions

    /// Every command method the fake browser received, in order.
    func receivedMethods() -> [String] {
        commands.map(\.method)
    }

    /// Whether a command with the given method was received.
    func received(_ method: String) -> Bool {
        commands.contains { $0.method == method }
    }

    /// The recorded commands matching `method`, in order.
    func commands(for method: String) -> [Command] {
        commands.filter { $0.method == method }
    }

    /// Every recorded command, in order.
    func allCommands() -> [Command] {
        commands
    }

    // MARK: Request handling (called by the channel)

    /// Handles one inbound JSON-RPC frame, returning the reply frame(s) to send
    /// back. A command (`id` present) yields a single response; anything else is
    /// dropped.
    func handle(frame: String) -> [String] {
        guard case .object = JSValue.parse(frame), let message = JSValue.parse(frame) else { return [] }
        guard let id = message["id"]?.intValue, let method = message["method"]?.stringValue else { return [] }
        let params = message["params"] ?? .object([])
        let sessionId = message["sessionId"]?.stringValue

        commands.append(Command(method: method, params: params, sessionId: sessionId))
        if method == "Page.navigate" { didNavigate = true }
        if method == "Runtime.evaluate", suppressEvaluateUntilNavigate, !didNavigate {
            return []
        }

        // Keystrokes land in the focused field, the way they would on a real page, so the
        // type path's read-back has something true to find. `text` is only present on the
        // char-producing event of each keystroke pair, so this counts each character once;
        // Backspace arrives as `key` and removes one.
        // Both ways a character reaches the field: per-keystroke `dispatchKeyEvent` for
        // ASCII, and one `Input.insertText` for text a key event cannot carry (the
        // non-ASCII path). Missing either reads back as an empty field.
        if method == "Input.dispatchKeyEvent" || method == "Input.insertText" {
            if let text = params["text"]?.stringValue, !text.isEmpty {
                typedValue += text
            } else if params["key"]?.stringValue == "Backspace", !typedValue.isEmpty {
                typedValue.removeLast()
            }
        }

        if methodsNotImplemented.contains(method) {
            let response = JSValue.object([
                ("id", .number(Double(id))),
                ("error", .object([
                    ("code", .number(-32601)),
                    ("message", .string("Method not found: \(method)"))
                ]))
            ])
            return [response.stringify()]
        }

        if method == "Page.captureScreenshot", screenshotFailRemaining > 0 {
            screenshotFailRemaining -= 1
            let response = JSValue.object([
                ("id", .number(Double(id))),
                ("error", .object([
                    ("code", .number(-32000)),
                    ("message", .string("No compositor surface"))
                ]))
            ])
            return [response.stringify()]
        }
        if method == "Page.captureScreenshot", screenshotEmptyRemaining > 0 {
            screenshotEmptyRemaining -= 1
            let response = JSValue.object([
                ("id", .number(Double(id))),
                ("result", .object([("data", .string(""))]))
            ])
            return [response.stringify()]
        }

        let result = result(forMethod: method, params: params, sessionId: sessionId)
        let response = JSValue.object([
            ("id", .number(Double(id))),
            ("result", result)
        ])
        return [response.stringify()]
    }

    private func result(forMethod method: String, params: JSValue, sessionId: String?) -> JSValue {
        switch method {
        case "Target.createTarget":
            let url = params["url"]?.stringValue ?? "about:blank"
            nextTargetSeq += 1
            let targetId = "target-\(nextTargetSeq)"
            targets[targetId] = FakeTarget(targetId: targetId, url: url, title: "Example Domain", type: "page")
            return .object([("targetId", .string(targetId))])

        case "Target.attachToTarget":
            let targetId = params["targetId"]?.stringValue ?? ""
            nextSessionSeq += 1
            let sid = "session-\(nextSessionSeq)"
            sessionToTarget[sid] = targetId
            lastSessionId = sid
            return .object([("sessionId", .string(sid))])

        case "Target.getTargets":
            let infos: [JSValue] = targets.values.map { target in
                .object([
                    ("targetId", .string(target.targetId)),
                    ("type", .string(target.type)),
                    ("url", .string(target.url)),
                    ("title", .string(target.title))
                ])
            }
            return .object([("targetInfos", .array(infos))])

        case "Target.closeTarget":
            let targetId = params["targetId"]?.stringValue ?? ""
            targets.removeValue(forKey: targetId)
            for (sid, tid) in sessionToTarget where tid == targetId { sessionToTarget.removeValue(forKey: sid) }
            return .object([("success", .bool(true))])

        case "Page.navigate":
            if let url = params["url"]?.stringValue, !url.isEmpty {
                pageUrl = url
            }
            return .object([("frameId", .string("frame-1"))])

        case "Network.getCookies":
            let entries = cookies.map { cookie in
                JSValue.object([("name", .string(cookie.name)), ("value", .string(cookie.value))])
            }
            return .object([("cookies", .array(entries))])

        case "Page.getNavigationHistory":
            let entries = navigationHistory.enumerated().map { offset, url in
                JSValue.object([
                    ("id", .number(Double(offset + 1))),
                    ("url", .string(url))
                ])
            }
            return .object([
                ("currentIndex", .number(Double(navigationIndex))),
                ("entries", .array(entries))
            ])

        case "Page.navigateToHistoryEntry":
            let entryId = Int(params["entryId"]?.doubleValue ?? 0)
            let targetIndex = entryId - 1
            if targetIndex >= 0, targetIndex < navigationHistory.count {
                navigationIndex = targetIndex
                pageUrl = navigationHistory[targetIndex]
            }
            return .object([])

        case "Runtime.terminateExecution":
            return .object([])

        case "Runtime.evaluate":
            let expression = params["expression"]?.stringValue ?? ""
            // The wake-path readyState probe expects an object back; report a
            // settled page so a real wake completes without polling its budget.
            if expression.contains("document.readyState") {
                let (url, title) = (pageUrl, pageTitle)
                var value: [(String, JSValue)] = [
                    ("ready", .string("complete")),
                    ("url", .string(url)),
                    ("title", .string(title))
                ]
                // The page-readiness probe additionally reads the body length; a
                // stable value lets the classifier settle on the first samples.
                if expression.contains("innerHTML") {
                    value.append(("len", .number(0)))
                }
                return .object([("result", .object([
                    ("type", .string("object")),
                    ("value", .object(value))
                ]))])
            }
            // The agent-code runner wrapper returns `{ result, error, pending }`;
            // recognise it by its private pending-queue marker and hand back the
            // scripted reply so the wired tab_execute path drains real pending ops.
            if expression.contains("__alohaPending"), let reply = agentRunnerPendingReply {
                // Mirror a page whose console fires while the agent code runs:
                // emit the scripted console events during the capture window.
                for event in consoleEventsOnAgentEval {
                    emitConsoleAPICalled(type: event.type, message: event.message)
                }
                return .object([("result", .object([("type", .string("object")), ("value", reply)]))])
            }
            // The interactive-markdown DOM walker script; recognized by its
            // `buildDomTree(` entry point regardless of the highlight/focusInteractive
            // args baked into it.
            if expression.contains("buildDomTree("), let domTreeReply {
                return .object([("result", .object([("type", .string("object")), ("value", .array(domTreeReply))]))])
            }
            // THE CLICK RECEIPT PROBES answer "" -- nothing covered, nothing hidden, no control
            // state, no form values -- rather than the body-text default below. Each of them treats
            // a non-empty string as a finding ("a layer was hidden", "the click was delivered to
            // <x>"), and the consent probe then withholds the click, so the default would turn every
            // happy-path click test into a refused one. Recognised by the markers the probes carry.
            if expression.contains("BEGIN overlay-hider js")
                || expression.contains("elementFromPoint")
                || expression.contains("aria-pressed")
                || expression.contains("input, textarea, select") {
                return .object([("result", .object([("type", .string("string")), ("value", .string(""))]))])
            }
            // A raw (unwrapped) `window.__aloha.<verb>(...)` call — see
            // `alohaRawCallReplies`'s doc comment.
            if let scripted = alohaRawCallReplies.first(where: { expression.contains($0.match) }) {
                return .object([("result", .object([("type", .string("object")), ("value", scripted.reply)]))])
            }
            // The `type` path's resolve-and-focus probe; the mock page always answers
            // with a real text input so keystroke dispatch proceeds. Matched on
            // `acceptsText` rather than a whole source line, which drifts.
            // The type path's value read-back (`ensureValueLanded`): answer with what the
            // keystrokes put in the field, not with the page body. Recognised by the
            // `typeof el.value` test the read script performs, which is stable while the
            // surrounding selector is not.
            if expression.contains("typeof el.value") {
                return .object([("result", .object([
                    ("type", .string("string")),
                    ("value", .string(typedValue))
                ]))])
            }
            if expression.contains("acceptsText") {
                return .object([("result", .object([("type", .string("object")), ("value", .object([
                    ("found", .bool(true)),
                    ("acceptsText", .bool(true)),
                    ("focused", .bool(true)),
                    ("tag", .string("INPUT")),
                    ("inputType", .string("text")),
                ]))]))])
            }
            return .object([("result", .object([("type", .string("string")), ("value", .string(bodyText))]))])

        case "Page.captureScreenshot":
            return .object([("data", .string(screenshotData))])

        case "Page.getLayoutMetrics":
            return .object([
                ("cssVisualViewport", .object([("clientWidth", .number(1024)), ("clientHeight", .number(768))])),
                ("contentSize", .object([("width", .number(1024)), ("height", .number(768))]))
            ])

        default:
            // Page.enable / Network.enable / Input.dispatchMouseEvent / Runtime.enable
            // and any other fire-and-acknowledge command: an empty result.
            return .object([])
        }
    }
}

// MARK: - MockCDPChannel

/// The ``CDPMessageChannel`` a ``CDPClient`` is built on. It forwards each sent
/// frame to the fake browser and hands the reply frames to the client's receive
/// loop, suspending `receive()` until a frame is available.
///
/// ## Frame ordering
/// A lock-guarded queue rather than an actor, so `inject` can be SYNCHRONOUS and
/// back-to-back frames are enqueued in call order. As an actor reached via
/// `Task { await … }` per frame it was flaky: unstructured actor jobs have no FIFO
/// guarantee, so frames raced and were delivered out of order.
private final class MockCDPChannel: CDPMessageChannel, @unchecked Sendable {
    private let browser: MockCDP
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false

    init(browser: MockCDP) { self.browser = browser }

    func open() async {}

    func send(_ text: String) async throws {
        let replies = await browser.handle(frame: text)
        for reply in replies { inject(reply) }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let frame = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: CDPError.connectionClosed)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() async {
        // The critical section lives in a synchronous helper: `NSLock.lock()` is
        // unavailable from an async context, since holding a lock across a suspension
        // would risk deadlock.
        markClosed()?.resume(throwing: CDPError.connectionClosed)
    }

    /// Marks the channel closed and hands back a parked `receive()` continuation, if
    /// any, for the caller to fail outside the lock.
    private func markClosed() -> CheckedContinuation<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        let pending = waiter
        waiter = nil
        return pending
    }

    /// Pushes a frame into the receive loop, as if the fake browser had produced it.
    ///
    /// SYNCHRONOUS, which is the whole point: back-to-back frames are enqueued in call
    /// order, so the client observes them in the order the fake browser produced them.
    func inject(_ frame: String) {
        lock.lock()
        if let pending = waiter {
            waiter = nil
            lock.unlock()
            pending.resume(returning: frame)
        } else {
            inbox.append(frame)
            lock.unlock()
        }
    }
}
