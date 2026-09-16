import Foundation
import ToolABI

// MARK: - File-input click teaching error

/// The refusal a plain click returns when its target is a file `<input>`.
/// Clicking it opens a native OS file-picker dialog the agent cannot see or
/// drive, so the turn loops on "File not uploaded". Refusing with a reason is
/// what stops the loop.
let fileInputClickRefusalMessage =
    "Do not click elements that open a file picker — the native dialog is invisible "
    + "to this tool and cannot be driven, so the click can never complete. Use "
    + "page_upload with the same aloha_id and absolute file paths instead"

// MARK: - Key chord parsing

public struct ParsedKeyChord: Equatable, Sendable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Parses a key-chord description (e.g. `"cmd+shift+a"`, `"Enter"`, `"a b c"`)
/// into a sequence of key presses with their modifiers.
public func parseKeyChordSequence(_ input: String) -> [ParsedKeyChord] {
    if input.contains(" ") && input.contains("+") {
        let parts = input.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var result: [ParsedKeyChord] = []
        for part in parts {
            result.append(contentsOf: parseKeyChordSequence(part))
        }
        return result
    }
    if input == "+" {
        return [ParsedKeyChord(key: "+", modifiers: [])]
    }
    if input.contains("+") {
        let tokens = input.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let key = tokens[tokens.count - 1]
        let modifierTokens = tokens.dropLast()
        var modifiers: [String] = []
        for token in modifierTokens {
            switch token.lowercased() {
            case "cmd", "command", "meta":
                modifiers.append("meta")
            case "ctrl", "control":
                modifiers.append("control")
            case "shift":
                modifiers.append("shift")
            case "alt", "option":
                modifiers.append("alt")
            default:
                break
            }
        }
        return [ParsedKeyChord(key: key, modifiers: modifiers)]
    }
    let namedKeys = [
        "Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowLeft", "ArrowRight",
        "ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", "Space",
        "Insert", "PrintScreen", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8",
        "F9", "F10", "F11", "F12"
    ]
    if let match = namedKeys.first(where: { $0.lowercased() == input.lowercased() }) {
        return [ParsedKeyChord(key: match, modifiers: [])]
    }
    return input.map { ParsedKeyChord(key: String($0), modifiers: []) }
}

// MARK: - Result serialization

/// Serializes an arbitrary agent result value to a string, JSON-encoding
/// objects/arrays and truncating very large payloads.
public func stringifyAgentResult(_ value: JSValue?) -> String {
    guard let value = value else { return "undefined" }
    switch value {
    case .null:
        return "null"
    case .undefined:
        return "undefined"
    case .string(let s):
        return s
    default:
        let limit = 50_000
        guard let encoded = jsValuePrettyJSON(value) else {
            return jsValueToPlainString(value)
        }
        if encoded.count > limit {
            return String(encoded.prefix(limit)) + "\n... (truncated)"
        }
        return encoded
    }
}

private func jsValueToPlainString(_ value: JSValue) -> String {
    switch value {
    case .null: return "null"
    case .undefined: return "undefined"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n):
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    case .string(let s): return s
    case .array, .object:
        return jsValuePrettyJSON(value) ?? ""
    }
}

/// Pretty-prints a JSValue with two-space indentation, preserving object key
/// insertion order, equivalent to `JSON.stringify(value, null, 2)`.
private func jsValuePrettyJSON(_ value: JSValue) -> String? {
    return prettyPrint(value, indent: 0)
}

private func prettyPrint(_ value: JSValue, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    let childPad = String(repeating: "  ", count: indent + 1)
    switch value {
    case .null, .undefined:
        return "null"
    case .bool(let b):
        return b ? "true" : "false"
    case .number(let n):
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    case .string(let s):
        return encodeJSONString(s)
    case .array(let arr):
        if arr.isEmpty { return "[]" }
        let items = arr.map { childPad + prettyPrint($0, indent: indent + 1) }
        return "[\n" + items.joined(separator: ",\n") + "\n" + pad + "]"
    case .object(let members):
        if members.isEmpty { return "{}" }
        let items = members.map { "\(childPad)\(encodeJSONString($0.0)): \(prettyPrint($0.1, indent: indent + 1))" }
        return "{\n" + items.joined(separator: ",\n") + "\n" + pad + "}"
    }
}

private func encodeJSONString(_ s: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [s]),
       let str = String(data: data, encoding: .utf8) {
        return String(str.dropFirst().dropLast())
    }
    return "\"\(s)\""
}

// MARK: - Console output formatting

/// A captured console message from the page during agent code execution.
public nonisolated struct ConsoleCapture: Equatable, Sendable {
    public var level: String
    public var msg: String

    public init(level: String, msg: String) {
        self.level = level
        self.msg = msg
    }
}

/// Formats captured console entries into a human-readable block, or an empty
/// string when there are none.
public func formatConsoleOutput(_ entries: [ConsoleCapture]) -> String {
    if entries.isEmpty { return "" }
    let lines = entries.map { "[\($0.level)] \($0.msg)" }
    return "Console output (\(entries.count) entries):\n" + lines.joined(separator: "\n")
}

// MARK: - Screenshot extension support

public func isSupportedScreenshotExtension(_ extensionWithDot: String) -> Bool {
    return extensionWithDot == ".png" || extensionWithDot == ".jpg" || extensionWithDot == ".jpeg"
}

/// Strips a `data:...,` prefix from a base64 string, returning everything after
/// the first comma (or the input unchanged when there is none).
public func stripDataUrlPrefix(_ value: String) -> String {
    guard let commaIndex = value.firstIndex(of: ",") else { return value }
    return String(value[value.index(after: commaIndex)...])
}

// MARK: - Action collector

public struct BridgeAction: Sendable {
    public var payload: JSValue
    public init(payload: JSValue) { self.payload = payload }
}

public final class ActionCollector {
    private var actions: [BridgeAction] = []

    public init() {}

    public func emit(_ action: BridgeAction) {
        actions.append(action)
    }

    public func drain() -> [BridgeAction] {
        return actions
    }

    public func size() -> Int {
        return actions.count
    }
}

// MARK: - Agent browser bridge

public struct AgentActionResult: Sendable {
    public var output: String
    public var isError: Bool
    public var pendingResults: [PendingResult]
    public var rawResult: JSValue?
    public var viewport: ViewportSize?
    public var imageSize: ViewportSize?

    public init(
        output: String,
        isError: Bool = false,
        pendingResults: [PendingResult] = [],
        rawResult: JSValue? = nil,
        viewport: ViewportSize? = nil,
        imageSize: ViewportSize? = nil
    ) {
        self.output = output
        self.isError = isError
        self.pendingResults = pendingResults
        self.rawResult = rawResult
        self.viewport = viewport
        self.imageSize = imageSize
    }
}

public nonisolated struct ViewportSize: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public nonisolated struct CapturedDownload: Sendable {
    public var filename: String
    public var sandboxPath: String
    public var sizeFormatted: String
    public init(filename: String, sandboxPath: String, sizeFormatted: String) {
        self.filename = filename
        self.sandboxPath = sandboxPath
        self.sizeFormatted = sizeFormatted
    }
}

public struct PendingResult: Sendable {
    public var type: String
    public var success: Bool
    public var error: String?
    public var data: JSValue?
    public var downloads: [CapturedDownload]

    public init(type: String, success: Bool, error: String? = nil, data: JSValue? = nil, downloads: [CapturedDownload] = []) {
        self.type = type
        self.success = success
        self.error = error
        self.data = data
        self.downloads = downloads
    }
}

/// The error AbortError surfaces when an agent operation is cancelled.
public nonisolated struct AgentAbortError: Error, Equatable, Sendable {
    public init() {}
}

public struct AgentCodeRunResult: Sendable {
    public var result: JSValue?
    public var error: AgentCodeError?
    public var pending: [PendingRequest]
    public init(result: JSValue?, error: AgentCodeError?, pending: [PendingRequest]) {
        self.result = result
        self.error = error
        self.pending = pending
    }
}

public struct AgentCodeError: Sendable {
    public var message: String
    public var stack: String?
    public var name: String
    public init(message: String, stack: String?, name: String) {
        self.message = message
        self.stack = stack
        self.name = name
    }
}

/// A pending request emitted by in-page agent code for the host to fulfil.
public struct PendingRequest: Sendable {
    public var type: String
    public var params: [String: JSValue]
    public init(type: String, params: [String: JSValue]) {
        self.type = type
        self.params = params
    }
}

/// Decodes the `{ result, error, pending }` object the
/// ``buildAgentCodeRunnerScript`` wrapper returns into a typed
/// ``AgentCodeRunResult``. A non-object value (e.g. a runtime that returned the
/// raw expression value) is treated as the bare result with no error / pending.
public func decodeAgentCodeRunResult(_ value: JSValue?) -> AgentCodeRunResult {
    guard let value, case let .object(members) = value else {
        return AgentCodeRunResult(result: value, error: nil, pending: [])
    }
    func member(_ key: String) -> JSValue? { members.last(where: { $0.0 == key })?.1 }

    let result = member("result")
    var error: AgentCodeError?
    if let errorValue = member("error"), case .object = errorValue {
        error = AgentCodeError(
            message: errorValue["message"]?.stringValue ?? "Error",
            stack: errorValue["stack"]?.stringValue,
            name: errorValue["name"]?.stringValue ?? "Error")
    }
    var pending: [PendingRequest] = []
    if let pendingValue = member("pending"), case let .array(items) = pendingValue {
        for item in items {
            guard case .object = item, let type = item["type"]?.stringValue else { continue }
            var params: [String: JSValue] = [:]
            if let paramsValue = item["params"], case let .object(paramMembers) = paramsValue {
                for (key, member) in paramMembers { params[key] = member }
            }
            pending.append(PendingRequest(type: type, params: params))
        }
    }
    return AgentCodeRunResult(result: result, error: error, pending: pending)
}

public nonisolated struct NavigationReadinessOptions: Sendable, Equatable {
    public var networkIdleThreshold: Int
    public var networkIdleTimeMs: Int
    public var domStableTimeMs: Int
    public var minWaitTimeMs: Int
    public var timeoutMs: Int

    public init(
        networkIdleThreshold: Int = 2,
        networkIdleTimeMs: Int = 500,
        domStableTimeMs: Int = 400,
        minWaitTimeMs: Int = 500,
        timeoutMs: Int = 12_000
    ) {
        self.networkIdleThreshold = networkIdleThreshold
        self.networkIdleTimeMs = networkIdleTimeMs
        self.domStableTimeMs = domStableTimeMs
        self.minWaitTimeMs = minWaitTimeMs
        self.timeoutMs = timeoutMs
    }
}

/// The minimal browser-driving surface the bridge needs. Implementations route
/// to the platform browser engine via the CDP abstraction; this module keeps
/// only the abstraction so it stays cross-platform.
public protocol AgentBridgeBackend: Sendable {
    func consumeAgentDownloads() -> [CapturedDownload]
    var isAborted: Bool { get }
    /// Parks this tab on a CAPTCHA the automatic solver could not clear and waits for
    /// a person to answer it, returning whether they did.
    func handOffCaptchaToHuman() async -> Bool
    func evaluateViaCdp(_ expression: String) async throws -> JSValue?
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue
    /// Widens the seam above rather than adding a second one, because reaching into
    /// a sealed region needs commands run inside an out-of-process frame's own
    /// renderer session: hit-testing from the parent session returns the `IFRAME`
    /// element for every point inside the frame and cannot discriminate at all, so a
    /// gate built on the parent session is no gate. See ``CDPSessionTarget``.
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue], on target: CDPSessionTarget) async throws -> JSValue
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)?
    /// The current viewport dimensions, if the layer is alive.
    func viewportDimensions() -> ViewportSize?
    /// Resolves a sandbox-relative save path to a host path, or nil when out of bounds.
    func resolveSandboxSavePath(_ path: String) -> String?
    /// Writes screenshot bytes to a host path, re-encoding to PNG when needed.
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws

    // MARK: Navigation seam

    /// The current page URL, read after a navigation settles.
    func currentURL() -> String
    /// Records a URL observed live in the document, so the layer's cached url stops
    /// being stale between navigations it did not drive. See ``PageBridge.liveURL``.
    func noteCurrentURL(_ url: String)
    /// Navigates the page to `url`, pacing the request through the per-domain
    /// limiter first when a `profileId` is present, then awaiting load + readiness.
    func navigate(url: String, profileId: String?, options: NavigationReadinessOptions) async throws
    /// Steps the navigation history back one entry, then awaits load + readiness.
    func goBack(options: NavigationReadinessOptions) async throws
    /// Drives the agent cursor toward `(x, y)` ahead of a synthetic mouse move.
    func animateCursorTo(x: Double, y: Double) async
    /// Terminates any in-flight `Runtime.evaluate` on the page (best-effort).
    func terminateExecution() async

    // MARK: Console capture seam

    /// Begins capturing the page's console output (`Runtime.consoleAPICalled`)
    /// for the duration of an agent-code execution, accumulating up to 50
    /// entries.
    func beginConsoleCapture() async
    func endConsoleCapture() async -> [ConsoleCapture]
}

/// CDP multiplexes every session over one connection, tagging each message with a
/// flat `sessionId` obtained from `Target.attachToTarget{flatten: true}`. Naming the
/// session explicitly is what lets the cross-origin reach path run its verification
/// inside a frame's own renderer while dispatching input in the page's.
public nonisolated enum CDPSessionTarget: Sendable, Equatable {
    /// The tab's own page session — what every pre-existing call site means.
    case page
    /// A flat session id, typically an out-of-process frame's own renderer session.
    case attached(String)
}

public nonisolated struct CDPSessionTargetUnsupportedError: Error, Equatable, Sendable {
    public let sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

public extension AgentBridgeBackend {
    /// Default routing for backends that only ever drive their own page session.
    ///
    /// `.page` forwards to the existing command, so no conformer changes. A request
    /// for another session throws rather than quietly falling back to the page — a
    /// silent fallback would run a hit test in the wrong session and return the wrong
    /// element while reporting success.
    @discardableResult
    func sendCdpCommand(
        domain: String, command: String, params: [String: JSValue], on target: CDPSessionTarget
    ) async throws -> JSValue {
        switch target {
        case .page:
            return try await sendCdpCommand(domain: domain, command: command, params: params)
        case .attached(let sessionId):
            throw CDPSessionTargetUnsupportedError(sessionId: sessionId)
        }
    }

    /// No hand-off wired, so a CAPTCHA the solver could not clear stays uncleared.
    func handOffCaptchaToHuman() async -> Bool { false }

    func currentURL() -> String { "" }
    func noteCurrentURL(_ url: String) {}
    func beginConsoleCapture() async {}
    func endConsoleCapture() async -> [ConsoleCapture] { [] }
    func navigate(url: String, profileId: String?, options: NavigationReadinessOptions) async throws {
        throw AgentNavigationUnsupportedError()
    }
    func goBack(options: NavigationReadinessOptions) async throws {
        throw AgentNavigationUnsupportedError()
    }
    func animateCursorTo(x: Double, y: Double) async {}
    func terminateExecution() async {}
}

public nonisolated struct AgentNavigationUnsupportedError: Error, Equatable, Sendable {
    public init() {}
}

/// The agent browser bridge. Drives clicks, typing, navigation, screenshots
/// and key presses through an injected backend, fulfilling the pending
/// requests emitted by in-page agent code.
public final class AgentBrowserBridge {
    public static let downloadWaitTimeoutMs: Double = 1500
    public static let downloadWaitPollMs: Double = 100

    private let backend: AgentBridgeBackend
    public let actionCollector: ActionCollector?
    /// The tab identity recorded on emitted actions (e.g. the post-exec snapshot).
    public let tabId: String?
    /// The directory captured-for-action screenshots are written into. When nil,
    /// no screenshot is captured and the action records a nil screenshot path.
    public let screenshotsDir: String?

    public init(
        backend: AgentBridgeBackend,
        actionCollector: ActionCollector? = nil,
        tabId: String? = nil,
        screenshotsDir: String? = nil
    ) {
        self.backend = backend
        self.actionCollector = actionCollector
        self.tabId = tabId
        self.screenshotsDir = screenshotsDir
    }

    private func throwIfAborted() throws {
        if backend.isAborted { throw AgentAbortError() }
    }

    private func isAbortError(_ error: Error) -> Bool {
        return error is AgentAbortError
    }

    public func waitForRecentAgentDownloads() async -> [CapturedDownload] {
        let first = backend.consumeAgentDownloads()
        if !first.isEmpty { return first }
        let deadline = Date().addingTimeInterval(Self.downloadWaitTimeoutMs / 1000)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(Self.downloadWaitPollMs * 1_000_000))
            let next = backend.consumeAgentDownloads()
            if !next.isEmpty { return next }
        }
        return []
    }

    /// Aborts propagate; per-request failures are captured as failed results.
    public func fulfillPendingRequests(_ pending: [PendingRequest]) async throws -> [PendingResult] {
        var results: [PendingResult] = []
        for request in pending {
            try throwIfAborted()
            var result: PendingResult
            do {
                result = try await handlePendingRequest(request)
                try throwIfAborted()
            } catch {
                if isAbortError(error) { throw error }
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                agentLog(.warn, "[PageBridge] pending:error type=\(request.type) err=\(message)")
                result = PendingResult(type: request.type, success: false, error: message)
            }
            results.append(result)
        }
        return results
    }

    /// Runs agent-authored code in the page and settles its pending CDP ops:
    /// the in-page `__aloha` runtime is installed (idempotent), the source is
    /// wrapped by ``buildAgentCodeRunnerScript`` and evaluated over the backend,
    /// then every queued op (`back` / `goto` / `drag` / `moveMouse` / …) is
    /// drained through ``fulfillPendingRequests`` so a page-global verb reaches
    /// CDP rather than silently enqueuing into `window.__alohaPending`. Returns the
    /// agent result plus the settled pending results; on a script/exec error the
    /// `{ isError, error }` envelope the script observes is returned.
    /// - Parameter compile: how the source reaches the page. `.inline` for a FIXED, Swift-constructed
    ///   call (the executor tools), `.dynamic` for arbitrary model-authored code. The distinction is
    ///   not cosmetic: `.dynamic` compiles a string in the page with `new Function`, which every
    ///   reddit row in the WebArena corpus had refused by Postmill's CSP — 19 rows, 14 of them
    ///   failures. See `AgentCodeCompilation`.
    public func executeAgentCode(_ source: String,
                                 compile: AgentCodeCompilation = .dynamic) async -> AgentActionResult {
        let startedAt = Date().timeIntervalSince1970 * 1000
        if backend.isAborted {
            return AgentActionResult(output: "Execution stopped", isError: true)
        }
        // Install the in-page runtime (idempotent — `if (window.__aloha) return`).
        _ = try? await backend.evaluateViaCdp(buildInpageAlohaRuntime())
        if backend.isAborted {
            return AgentActionResult(output: "Execution stopped", isError: true)
        }

        await backend.beginConsoleCapture()

        let runValue: JSValue?
        do {
            runValue = try await backend.evaluateViaCdp(
                buildAgentCodeRunnerScript(source, compile: compile))
            try throwIfAborted()
        } catch {
            let consoleOutput = formatConsoleOutput(await backend.endConsoleCapture())
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            // A navigation (or same-target document swap) that destroyed the JS
            // execution context while the awaited evaluate was still in flight is
            // NOT a failure: the agent's own code triggered the navigation. Chromium
            // reports it as `-32000 "Inspected target navigated or closed"`. Settle the
            // new document and report SUCCESS with its URL — otherwise the agent reads
            // a phantom failure and retries a step that already landed.
            if isBenignNavigationRace(error) {
                let settledURL = await settleAfterNavigationRace()
                var message =
                    settledURL.map { "Code executed; it triggered a navigation. The page is now at \($0)." }
                    ?? "Code executed; it triggered a navigation."
                if !consoleOutput.isEmpty { message += "\n\n\(consoleOutput)" }
                return AgentActionResult(output: message, isError: false)
            }
            var message = "Execution failed: \(errorMessage(error))"
            if !consoleOutput.isEmpty { message += "\n\n\(consoleOutput)" }
            return AgentActionResult(output: message, isError: true)
        }

        let consoleEntries = await backend.endConsoleCapture()
        let consoleOutput = formatConsoleOutput(consoleEntries)

        let run = decodeAgentCodeRunResult(runValue)
        if let scriptError = run.error {
            var message = "Execution error (\(scriptError.name)): \(scriptError.message)"
            if let stack = scriptError.stack { message += "\n\nStack trace:\n\(stack)" }
            if !consoleOutput.isEmpty { message += "\n\n\(consoleOutput)" }
            return AgentActionResult(output: message, isError: true)
        }

        let pendingResults: [PendingResult]
        do {
            pendingResults = try await fulfillPendingRequests(run.pending)
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Bridge operation failed: \(errorMessage(error))", isError: true)
        }

        var output = "Code executed successfully.\n\nResult:\n\(stringifyAgentResult(run.result))"
        if !pendingResults.isEmpty {
            let lines = pendingResults.map { "  \($0.type): \($0.success ? "OK" : ($0.error ?? "error"))" }
            output += "\n\nBridge operations:\n" + lines.joined(separator: "\n")
        }
        if !consoleOutput.isEmpty {
            output += "\n\n\(consoleOutput)"
        }
        if actionCollector != nil, !backend.isAborted {
            await emitPostExecSnapshot(startedAt: startedAt)
        }
        return AgentActionResult(
            output: output,
            isError: false,
            pendingResults: pendingResults,
            rawResult: run.result)
    }

    /// Classifies a thrown evaluate error as a benign navigation race: the page
    /// navigated (or the inspected document was swapped) while an awaited
    /// `Runtime.evaluate` was in flight, destroying its JS execution context.
    /// Chromium reports it as `-32000 "Inspected target navigated or closed"`;
    /// other stacks word the same condition "Execution context was destroyed, most
    /// likely because of a navigation", which is why both spellings are matched.
    /// A genuine transport/target loss (socket closed, browser gone, crash) is NOT
    /// benign and stays a hard error.
    func isBenignNavigationRace(_ error: Error) -> Bool {
        let message = errorMessage(error).lowercased()
        let fatal = [
            "websocket", "connection closed", "browser has been closed",
            "browser closed", "no browser", "disconnected", "has crashed", "target crashed",
        ]
        if fatal.contains(where: { message.contains($0) }) { return false }
        return message.contains("inspected target navigated or closed")
            || message.contains("execution context was destroyed")
            || message.contains("navigated or closed")
            || message.contains("context was destroyed")
    }

    /// The page's current URL, straight from the backend's navigation seam (no JS evaluate).
    ///
    /// EXISTS FOR THE ACTION RECEIPTS. `Clicked element "2s" (single).` carries no page state, so a
    /// click that did nothing is indistinguishable from one that worked — measured on the WebArena
    /// corpus, 44 rows answered immediately after a receipt of exactly that shape. A tool can now read
    /// the URL either side of its action and say whether anything moved, for the cost of two backend
    /// property reads and no round trip.
    public func currentPageURL() -> String { backend.currentURL() }

    /// The URL of the document that is actually loaded, read inside the page, and written back
    /// into the layer's cache.
    ///
    /// MEASURED against a real Chrome 152: `backend.currentURL()` returns the tabs model's cached
    /// `session.url`, and the only writers of that are the navigation waiter and the read probe —
    /// neither of which a click runs. So a click that navigated left the cache holding the
    /// pre-click URL, and BOTH readers of it lied: the receipt said `The page did NOT navigate —
    /// still at https://example.com/` about a click that had landed on iana.org, and the very next
    /// `manage_tabs list` printed example.com for a tab that was on iana.org.
    ///
    /// nil when the read did not land — including the mid-commit `execution context was destroyed`,
    /// which is itself evidence a navigation is in flight, so the caller treats it as "still moving"
    /// rather than as "did not move".
    func liveURL() async -> String? {
        guard let url = (try? await backend.evaluateViaCdp("location.href"))??.stringValue,
              !url.isEmpty else { return nil }
        backend.noteCurrentURL(url)
        return url
    }

    /// The page's URL after an action, once the page has had a bounded chance to move.
    ///
    /// `currentPageURL()` read immediately after a click is read BEFORE the navigation commits, so
    /// `PageDelta.describe` compared the old URL with itself and asserted "The page did NOT navigate"
    /// about a page that was navigating. Measured on the 158-task WebArena preset: **702 such receipts
    /// across 158 traces, 190 of them (27%) factually false** — the next round's `<active_tab url=…>`
    /// differs from the URL the receipt named — spread over 93 of the 158 tasks.
    ///
    /// Two consequences, from the one bad read. The grader is misinformed: the harness takes the URL of
    /// the last tool call as the attempt's `final_url` and a fresh browser is pointed at it, so three
    /// tasks whose live page matched the gold were scored against the page before the click.
    /// And the caller is misinformed in a way that compounds: an agent that fingerprints the last
    /// tool result sees two clicks which both falsely report "still at X" as byte-identical, reads
    /// that as no progress, and starts firing its loop-breaking heuristics on a lie.
    ///
    /// COSTS NOTHING WHEN NOTHING MOVES, which is the common case: the grace poll exits on the first
    /// tick that shows a different URL, and a click that genuinely did not navigate pays the window
    /// once. `settleAfterNavigationRace` alone is not enough here — right after a click the OLD page is
    /// still `complete`, so it would return immediately with the stale URL, which is the bug.
    /// 250ms, not 600: a click that does NOT navigate is the common case (a
    /// Magento admin grid never changes its URL), and each one paid the whole
    /// window — 25 clicks were 15s of a single turn's budget.
    ///
    /// The early exit polls ``liveURL`` — a live `location.href` inside the document — because the
    /// cached `session.url` it used to poll is never written by a click, so the exit could not fire
    /// and every receipt said "did NOT navigate". Costs one CDP evaluate per 50ms tick; a click that
    /// really did not move the page pays the 250ms window once, as before.
    func settledPageURL(after urlBefore: String, graceMs: Double = 250,
                        pollMs: UInt64 = 50) async -> String {
        let deadline = Date().addingTimeInterval(graceMs / 1000)
        while Date() < deadline {
            if backend.isAborted { break }
            guard let now = await liveURL() else {
                // The context died under the read: a navigation is committing. Wait for the new
                // document rather than reporting the page it is leaving.
                if let settled = await settleAfterNavigationRace(), settled != urlBefore { return settled }
                continue
            }
            if now != urlBefore {
                // It moved. Let the new document commit before naming it, so the receipt does not
                // report a URL the page is still leaving.
                return await settleAfterNavigationRace() ?? now
            }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
        return await liveURL() ?? backend.currentURL()
    }

    func settleAfterNavigationRace(timeoutMs: Double = 6000, pollMs: UInt64 = 150) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutMs / 1000)
        while Date() < deadline {
            if backend.isAborted { break }
            var ready: String?
            do { ready = try await backend.evaluateViaCdp("document.readyState")?.stringValue } catch { ready = nil }
            if ready == "complete" || ready == "interactive" { break }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
        // The live href, not the cache: the cache is exactly what this function is unsticking.
        return await liveURL()
    }

    private func emitPostExecSnapshot(startedAt: Double) async {
        guard let collector = actionCollector else { return }
        let completedAt = Date().timeIntervalSince1970 * 1000
        let actionId = generateActionId()
        let screenshotPath = await captureScreenshotForAction(actionId)
        let base = ActionBuilderBase(
            tabId: tabId,
            screenshotPath: screenshotPath,
            startedAt: startedAt,
            completedAt: completedAt)
        let action = buildSnapshotAction(base, reason: "post-exec")
        collector.emit(BridgeAction(payload: agentActionJSValue(action)))
        agentLog(.info, "[PageBridge] post-exec snapshot emitted tab=\(tabId ?? "?") hasScreenshot=\(screenshotPath != nil)")
    }

    private func captureScreenshotForAction(_ actionId: String) async -> String? {
        guard let directory = screenshotsDir else { return nil }
        guard let captured = try? await backend.captureViewport(), !captured.base64.isEmpty else { return nil }
        let path = (directory as NSString).appendingPathComponent("\(actionId).jpg")
        do {
            try await backend.writeScreenshot(base64: captured.base64, hostPath: path, isPng: false)
            return path
        } catch {
            agentLog(.warn, "[PageBridge] post-exec screenshot write failed: \(error)")
            return nil
        }
    }

    private func handlePendingRequest(_ request: PendingRequest) async throws -> PendingResult {
        switch request.type {
        case "pressKeys":
            let keys = request.params["keys"]?.stringValue ?? ""
            let r = await pressKeys(keys)
            return PendingResult(type: "pressKeys", success: !r.isError, error: r.isError ? r.output : nil)
        case "typeText":
            let text = request.params["text"]?.stringValue ?? ""
            let r = await typeText(text)
            return PendingResult(type: "typeText", success: !r.isError, error: r.isError ? r.output : nil)
        case "type":
            let alohaId = request.params["alohaId"]?.stringValue ?? ""
            let text = request.params["text"]?.stringValue ?? ""
            // Default REPLACE (see DefaultBridgeExecutors): typing sets a value, it does not
            // append — an append default doubled re-typed fields (login username -> loop).
            let replace = request.params["replace"]?.boolValue ?? true
            let r = await type(alohaId, text, replace: replace)
            return PendingResult(type: "type", success: !r.isError, error: r.isError ? r.output : nil)
        case "click":
            return await handleClickPendingRequest(request)
        case "doubleClick":
            return await handleMouseClickPendingRequest(request, kind: .double)
        case "tripleClick":
            return await handleMouseClickPendingRequest(request, kind: .triple)
        case "rightClick":
            return await handleMouseClickPendingRequest(request, kind: .right)
        case "hover":
            return await handleHoverPendingRequest(request)
        case "goto":
            let url = request.params["url"]?.stringValue ?? ""
            let r = await goto(url)
            return PendingResult(
                type: "goto",
                success: !r.isError,
                error: r.isError ? r.output : nil,
                data: .object([("url", .string(backend.currentURL()))]))
        case "back":
            let r = await back()
            return PendingResult(
                type: "back",
                success: !r.isError,
                error: r.isError ? r.output : nil,
                data: .object([("url", .string(backend.currentURL()))]))
        case "scrollTo":
            let alohaId = request.params["alohaId"]?.stringValue ?? ""
            let r = await scrollTo(alohaId)
            return PendingResult(type: "scrollTo", success: !r.isError, error: r.isError ? r.output : nil)
        case "drag":
            let r = await drag(request.params)
            return PendingResult(type: "drag", success: !r.isError, error: r.isError ? r.output : nil)
        case "moveMouse":
            let r = await moveMouse(request.params)
            return PendingResult(type: "moveMouse", success: !r.isError, error: r.isError ? r.output : nil)
        case "screenshot":
            return await handleScreenshotPendingRequest(request)
        default:
            return PendingResult(type: request.type, success: false, error: "Unknown pending type: \(request.type)")
        }
    }

    private func handleScreenshotPendingRequest(_ request: PendingRequest) async -> PendingResult {
        let requestedViewport = decodeViewportSize(request.params["viewport"])
        if let saveTo = request.params["saveTo"]?.stringValue, !saveTo.isEmpty {
            let outcome = await screenshotToPath(saveTo)
            switch outcome {
            case let .failure(message):
                return PendingResult(type: "screenshot", success: false, error: message)
            case let .success(viewport, imageSize):
                let resolvedViewport = requestedViewport ?? viewport
                var data: [(String, JSValue)] = [("path", .string(saveTo))]
                if let resolvedViewport { data.append(("viewport", viewportJSValue(resolvedViewport))) }
                if let imageSize { data.append(("imageSize", viewportJSValue(imageSize))) }
                return PendingResult(type: "screenshot", success: true, data: .object(data))
            }
        }
        let result = await screenshot()
        let resolvedViewport = requestedViewport ?? result.viewport
        let data: JSValue?
        if let resolvedViewport {
            var fields: [(String, JSValue)] = [("base64", result.rawResult ?? .null)]
            fields.append(("viewport", viewportJSValue(resolvedViewport)))
            if let imageSize = result.imageSize { fields.append(("imageSize", viewportJSValue(imageSize))) }
            data = .object(fields)
        } else {
            data = result.rawResult
        }
        return PendingResult(
            type: "screenshot",
            success: !result.isError,
            error: result.isError ? result.output : nil,
            data: data)
    }

    private enum ScreenshotToPathOutcome {
        case success(viewport: ViewportSize?, imageSize: ViewportSize?)
        case failure(String)
    }

    private func screenshotToPath(_ path: String) async -> ScreenshotToPathOutcome {
        let target = resolveScreenshotSaveTarget(path)
        guard target.ok, let resolvedPath = target.resolvedPath, let ext = target.extension else {
            return .failure(target.error ?? "Failed to capture screenshot")
        }
        let captured: (base64: String, imageWidth: Int, imageHeight: Int)?
        do {
            try throwIfAborted()
            captured = try await backend.captureViewport()
            try throwIfAborted()
        } catch {
            if isAbortError(error) { return .failure("Execution stopped") }
            return .failure("Screenshot failed: \(errorMessage(error))")
        }
        guard let captured else { return .failure("Failed to capture screenshot") }
        do {
            try throwIfAborted()
            try await backend.writeScreenshot(base64: captured.base64, hostPath: resolvedPath, isPng: ext == ".png")
            try throwIfAborted()
        } catch {
            if isAbortError(error) { return .failure("Execution stopped") }
            return .failure("Failed to write screenshot to \(path): \(errorMessage(error))")
        }
        return .success(
            viewport: backend.viewportDimensions(),
            imageSize: ViewportSize(width: captured.imageWidth, height: captured.imageHeight))
    }

    private func decodeViewportSize(_ value: JSValue?) -> ViewportSize? {
        guard let value,
              let width = value["width"]?.doubleValue,
              let height = value["height"]?.doubleValue else { return nil }
        return ViewportSize(width: Int(width), height: Int(height))
    }

    private func viewportJSValue(_ size: ViewportSize) -> JSValue {
        .object([("width", .number(Double(size.width))), ("height", .number(Double(size.height)))])
    }

    public func pressKeys(_ keys: String) async -> AgentActionResult {
        do {
            // Never enter credentials: refuse when the focused element is a
            // credential field (the focus-then-pressKeys bypass of the id-based guard).
            if credentialGuardEnabled(), let snapshot = try await resolveFocusedElementSnapshot(), isPasswordField(snapshot) {
                return AgentActionResult(output: credentialFieldRefusalMessage, isError: true)
            }
            let sequence = parseKeyChordSequence(keys)
            for chord in sequence {
                try throwIfAborted()
                try await emulateKeyChordViaCdp(chord)
            }
            return AgentActionResult(output: "Keys \"\(keys)\" sent successfully")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Failed to send keys: \(errorMessage(error))", isError: true)
        }
    }

    public func typeText(_ text: String) async -> AgentActionResult {
        do {
            // Never enter credentials: refuse when the focused element is a
            // credential field (the focus-then-typeText bypass of the id-based guard).
            if credentialGuardEnabled(), let snapshot = try await resolveFocusedElementSnapshot(), isPasswordField(snapshot) {
                return AgentActionResult(output: credentialFieldRefusalMessage, isError: true)
            }
            try await typeCDP(text, replace: false)
            return AgentActionResult(output: "Typed text into focused element")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Type text failed: \(errorMessage(error))", isError: true)
        }
    }

    public func scrollTo(_ alohaId: String) async -> AgentActionResult {
        do {
            let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            (function() {
              var el = document.querySelector('[aloha-id="\(escaped)"]');
              if (!el) return { found: false };
              el.scrollIntoView({ block: 'center', behavior: 'smooth' });
              var rect = el.getBoundingClientRect();
              var inViewport = rect.top >= 0 && rect.left >= 0
                && rect.bottom <= window.innerHeight && rect.right <= window.innerWidth;
              return { found: true, inViewport: inViewport };
            })()
            """
            let maxAttempts = 3
            for _ in 0..<maxAttempts {
                let value = try await backend.evaluateViaCdp(script)
                guard let value = value, value.objectMember("found")?.boolValue == true else {
                    return AgentActionResult(output: "Element with aloha-id \(alohaId) not found", isError: true)
                }
                if value.objectMember("inViewport")?.boolValue == true {
                    return AgentActionResult(output: "Scrolled to element \(alohaId)")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return AgentActionResult(output: "Scrolled to element \(alohaId) (may be partially visible)")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Scroll failed: \(errorMessage(error))", isError: true)
        }
    }

    private static let navigationReadiness = NavigationReadinessOptions(
        networkIdleThreshold: 2,
        networkIdleTimeMs: 500,
        domStableTimeMs: 400,
        minWaitTimeMs: 500,
        timeoutMs: 12_000)

    /// The profile whose daily per-domain budget the rate limiter charges a
    /// navigation against, when known.
    public var profileId: String? { _profileId }
    private var _profileId: String?

    @discardableResult
    public func boundToProfile(_ profileId: String?) -> AgentBrowserBridge {
        _profileId = profileId
        return self
    }

    public func goto(_ url: String) async -> AgentActionResult {
        do {
            try throwIfAborted()
            try await backend.navigate(url: url, profileId: _profileId, options: Self.navigationReadiness)
            try throwIfAborted()
            return AgentActionResult(output: "Navigated to \(backend.currentURL())")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Navigation failed: \(errorMessage(error))", isError: true)
        }
    }

    public func back() async -> AgentActionResult {
        do {
            try throwIfAborted()
            try await backend.goBack(options: Self.navigationReadiness)
            try throwIfAborted()
            return AgentActionResult(output: "Navigated back to \(backend.currentURL())")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Go back failed: \(errorMessage(error))", isError: true)
        }
    }

    public func drag(_ params: [String: JSValue]) async -> AgentActionResult {
        let fromX = params["fromX"]?.doubleValue ?? 0
        let fromY = params["fromY"]?.doubleValue ?? 0
        let toX = params["toX"]?.doubleValue ?? 0
        let toY = params["toY"]?.doubleValue ?? 0
        let steps = Int(params["steps"]?.doubleValue ?? 0)
        let resolvedSteps = steps > 0 ? steps : 10
        let duration = params["duration"]?.doubleValue ?? 0
        let resolvedDuration = duration > 0 ? duration : 300
        let stepDelayMs = max(resolvedDuration / Double(resolvedSteps), 5)
        do {
            _ = try await sendMouseEvent(type: "mouseMoved", x: roundCoord(fromX), y: roundCoord(fromY))
            try await abortableDelay(50)
            _ = try await sendMouseEvent(
                type: "mousePressed", x: roundCoord(fromX), y: roundCoord(fromY),
                button: "left", clickCount: 1)
            try await abortableDelay(50)
            for step in 1...resolvedSteps {
                try throwIfAborted()
                let progress = Double(step) / Double(resolvedSteps)
                let x = roundCoord(fromX + (toX - fromX) * progress)
                let y = roundCoord(fromY + (toY - fromY) * progress)
                _ = try await sendMouseEvent(type: "mouseMoved", x: x, y: y, button: "left")
                try await abortableDelay(stepDelayMs)
            }
            _ = try await sendMouseEvent(
                type: "mouseReleased", x: roundCoord(toX), y: roundCoord(toY),
                button: "left", clickCount: 1)
            return AgentActionResult(output: "Dragged from (\(roundCoord(fromX)), \(roundCoord(fromY))) to (\(roundCoord(toX)), \(roundCoord(toY)))")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Drag failed: \(errorMessage(error))", isError: true)
        }
    }

    public func moveMouse(_ params: [String: JSValue]) async -> AgentActionResult {
        let x = params["x"]?.doubleValue ?? 0
        let y = params["y"]?.doubleValue ?? 0
        do {
            await backend.animateCursorTo(x: x, y: y)
            try throwIfAborted()
            _ = try await sendMouseEvent(type: "mouseMoved", x: roundCoord(x), y: roundCoord(y))
            return AgentActionResult(output: "Moved mouse to (\(roundCoord(x)), \(roundCoord(y)))")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Move mouse failed: \(errorMessage(error))", isError: true)
        }
    }

    private func roundCoord(_ value: Double) -> Int { Int(value.rounded()) }

    @discardableResult
    private func sendMouseEvent(
        type: String, x: Int, y: Int, button: String? = nil, clickCount: Int? = nil
    ) async throws -> JSValue {
        try throwIfAborted()
        var params: [String: JSValue] = [
            "type": .string(type),
            "x": .number(Double(x)),
            "y": .number(Double(y))
        ]
        if let button { params["button"] = .string(button) }
        if let clickCount { params["clickCount"] = .number(Double(clickCount)) }
        let result = try await backend.sendCdpCommand(domain: "Input", command: "dispatchMouseEvent", params: params)
        try throwIfAborted()
        return result
    }

    private enum MouseClickKind {
        case double
        case triple
        case right
    }

    /// Settles a queued `click`: the in-page runtime resolved the element to
    /// viewport `x`/`y` (or the agent passed raw coords), so the host animates
    /// the cursor and dispatches the press/release pair at those coordinates.
    private func handleClickPendingRequest(_ request: PendingRequest) async -> PendingResult {
        let x = request.params["x"]?.doubleValue ?? 0
        let y = request.params["y"]?.doubleValue ?? 0
        // A plain click on a file <input> pops a native OS file-picker the agent
        // cannot see or drive (see `fileInputClickRefusalMessage`). Classify via the
        // same id-based snapshot the credential guard uses; fail open when the target
        // is unresolved.
        if let alohaId = request.params["alohaId"]?.stringValue, !alohaId.isEmpty {
            let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
            if let snapshot = try? await resolveElementSnapshot(escaped), snapshot.inputType == "file" {
                return PendingResult(type: "click", success: false, error: fileInputClickRefusalMessage)
            }
        }
        do {
            try await dispatchClick(x: x, y: y, button: "left", clickCount: 1)
            let downloads = await waitForRecentAgentDownloads()
            return PendingResult(
                type: "click",
                success: true,
                data: .object([("x", .number(x)), ("y", .number(y))]),
                downloads: downloads)
        } catch {
            if isAbortError(error) { return PendingResult(type: "click", success: false, error: "Execution stopped") }
            return PendingResult(type: "click", success: false, error: errorMessage(error))
        }
    }

    /// Settles a queued `doubleClick` / `tripleClick` / `rightClick` at the
    /// coordinates the in-page runtime already resolved.
    private func handleMouseClickPendingRequest(_ request: PendingRequest, kind: MouseClickKind) async -> PendingResult {
        let x = request.params["x"]?.doubleValue ?? 0
        let y = request.params["y"]?.doubleValue ?? 0
        let label: String
        let button: String
        let clickCount: Int
        switch kind {
        case .double: label = "doubleClick"; button = "left"; clickCount = 2
        case .triple: label = "tripleClick"; button = "left"; clickCount = 3
        case .right: label = "rightClick"; button = "right"; clickCount = 1
        }
        do {
            try await dispatchClick(x: x, y: y, button: button, clickCount: clickCount)
            if kind == .double {
                let downloads = await waitForRecentAgentDownloads()
                return PendingResult(type: label, success: true, downloads: downloads)
            }
            return PendingResult(type: label, success: true)
        } catch {
            if isAbortError(error) { return PendingResult(type: label, success: false, error: "Execution stopped") }
            return PendingResult(type: label, success: false, error: errorMessage(error))
        }
    }

    /// Settles a queued `hover` by moving the host mouse to the page-resolved
    /// coordinates so the page receives a real CDP `mouseMoved`. The in-page
    /// runtime has already fired the synthetic pointer/mouse-enter events; this
    /// adds the genuine CDP move.
    private func handleHoverPendingRequest(_ request: PendingRequest) async -> PendingResult {
        guard let x = request.params["x"]?.doubleValue,
              let y = request.params["y"]?.doubleValue else {
            return PendingResult(type: "hover", success: true)
        }
        do {
            await backend.animateCursorTo(x: x, y: y)
            _ = try await sendMouseEvent(type: "mouseMoved", x: roundCoord(x), y: roundCoord(y))
            return PendingResult(type: "hover", success: true)
        } catch {
            if isAbortError(error) { return PendingResult(type: "hover", success: false, error: "Execution stopped") }
            return PendingResult(type: "hover", success: false, error: errorMessage(error))
        }
    }

    private func dispatchClick(x: Double, y: Double, button: String, clickCount: Int) async throws {
        try throwIfAborted()
        await backend.animateCursorTo(x: x, y: y)
        let rx = roundCoord(x)
        let ry = roundCoord(y)
        _ = try await sendMouseEvent(type: "mouseMoved", x: rx, y: ry)
        try await abortableDelay(50)
        _ = try await sendMouseEvent(type: "mousePressed", x: rx, y: ry, button: button, clickCount: clickCount)
        try await abortableDelay(50)
        _ = try await sendMouseEvent(type: "mouseReleased", x: rx, y: ry, button: button, clickCount: clickCount)
    }

    /// Resolves the in-page element identified by an already-escaped `aloha-id`
    /// into a typed snapshot (bbox + field-identifying attributes) for
    /// classification — e.g. the P0.1 credential-field guard. Returns `nil` when
    /// the element cannot be found, so callers fail open for unresolved targets.
    private func resolveElementSnapshot(_ escapedAlohaId: String) async throws -> ElementSnapshot? {
        let value = try await backend.evaluateViaCdp("""
        (function() {
          var el = document.querySelector('[aloha-id="\(escapedAlohaId)"]');
          if (!el) return null;
          var r = el.getBoundingClientRect();
          return {
            bbox: { x: r.x, y: r.y, width: r.width, height: r.height },
            tagName: (el.tagName || '').toLowerCase(),
            label: '',
            role: '',
            inputType: (el.getAttribute('type') || '').toLowerCase(),
            name: el.getAttribute('name'),
            htmlId: el.id || null,
            ariaLabel: el.getAttribute('aria-label'),
            placeholder: el.getAttribute('placeholder')
          };
        })()
        """)
        return decodeElementSnapshot(value)
    }

    /// Resolves the credential-classification snapshot for the page's currently
    /// FOCUSED element (`document.activeElement`), so `typeText` (which targets the
    /// focused element, not an id) can refuse a credential field too.
    private func resolveFocusedElementSnapshot() async throws -> ElementSnapshot? {
        let value = try await backend.evaluateViaCdp("""
        (function() {
          var el = document.activeElement;
          if (!el) return null;
          var r = el.getBoundingClientRect();
          return {
            bbox: { x: r.x, y: r.y, width: r.width, height: r.height },
            tagName: (el.tagName || '').toLowerCase(),
            label: '',
            role: '',
            inputType: (el.getAttribute('type') || '').toLowerCase(),
            name: el.getAttribute('name'),
            htmlId: el.id || null,
            ariaLabel: el.getAttribute('aria-label'),
            placeholder: el.getAttribute('placeholder')
          };
        })()
        """)
        return decodeElementSnapshot(value)
    }

    /// Types `text` into the element identified by `alohaId`: the element is
    /// scrolled into view and focused in the page first, then the text rides CDP
    /// key events into it. `replace` clears the existing value first.
    public func type(_ alohaId: String, _ text: String, replace: Bool) async -> AgentActionResult {
        do {
            try throwIfAborted()
            let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
            // P0.1: never enter credentials. Classify the target before focusing
            // or typing; refuse a password/credential field outright (no
            // keystrokes are dispatched) and tell the model to ask the user.
            if credentialGuardEnabled(),
               let snapshot = try await resolveElementSnapshot(escaped),
               isPasswordField(snapshot) {
                return AgentActionResult(output: credentialFieldRefusalMessage, isError: true)
            }
            // FAIL CLOSED on an unresolved id: typing must never fall through to
            // whatever element happens to hold focus — that silent mis-type
            // reported success while the keystrokes landed in the wrong document.
            //
            // Resolving is not enough — the probe checks both things that decide whether
            // the keystrokes land: that the element is a KIND that holds text, and that
            // the focus actually TOOK (`document.activeElement`, descended through shadow
            // roots). The second is not redundant: a hidden or readonly input passes the
            // kind check and still swallows everything, which reported a false success.
            let probe = try await backend.evaluateViaCdp("""
            (function() {
              var el = document.querySelector('[aloha-id="\(escaped)"]');
              if (!el) return { found: false };
              var tag = el.tagName;
              var inputType = (el.getAttribute('type') || 'text').toLowerCase();
              var nonText = ['button','submit','reset','checkbox','radio','file','image','range','color','hidden'];
              var accepts = (tag === 'TEXTAREA'
                  || (tag === 'INPUT' && nonText.indexOf(inputType) === -1)
                  || el.isContentEditable === true)
                && el.disabled !== true && el.readOnly !== true;
              if (accepts) { el.scrollIntoView({ block: 'center', behavior: 'instant' }); el.focus(); }
              var active = document.activeElement;
              while (active && active.shadowRoot && active.shadowRoot.activeElement) {
                active = active.shadowRoot.activeElement;
              }
              return {
                found: true,
                acceptsText: accepts,
                focused: active === el,
                tag: tag,
                inputType: tag === 'INPUT' ? inputType : ''
              };
            })()
            """)
            guard probe?.objectMember("found")?.boolValue == true else {
                return AgentActionResult(output: "Element with aloha-id \(alohaId) not found", isError: true)
            }
            let tag = (probe?.objectMember("tag")?.stringValue ?? "unknown").lowercased()
            let inputType = probe?.objectMember("inputType")?.stringValue ?? ""
            let kind = inputType.isEmpty ? "<\(tag)>" : "<\(tag) type=\(inputType)>"
            guard probe?.objectMember("acceptsText")?.boolValue == true else {
                return AgentActionResult(
                    output: "Element with aloha-id \(alohaId) cannot accept typed text (it is \(kind)). "
                        + "No keystrokes were sent. Re-read the page and pass the aloha-id of the text field itself.",
                    isError: true)
            }
            guard probe?.objectMember("focused")?.boolValue == true else {
                return AgentActionResult(
                    output: "Element with aloha-id \(alohaId) (\(kind)) could not take keyboard focus — it is hidden, "
                        + "detached or focus was moved away, so nothing would be typed into it. No keystrokes were "
                        + "sent. Re-read the page and pass the aloha-id of the VISIBLE field.",
                    isError: true)
            }
            try await typeCDP(text, replace: replace)
            return AgentActionResult(output: "Typed text into element \(alohaId)")
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Type failed: \(errorMessage(error))", isError: true)
        }
    }

    private func abortableDelay(_ milliseconds: Double) async throws {
        try throwIfAborted()
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds) * 1_000_000))
        try throwIfAborted()
    }

    /// Delay (ms) inserted AFTER each typed key. With no inter-key pause the
    /// keystroke burst arrives faster than an input that re-renders or tokenizes on
    /// each keystroke can process it, so it drops the character right after a
    /// separator — the openaloha runner hit this on GitLab's filtered-search bar and
    /// settled on "~120ms is reliable". The CDP round-trip already adds a little, so
    /// the explicit pause is set a touch below that.
    private static let interKeyDelayMs: Double = 100

    private func typeCDP(_ text: String, replace: Bool) async throws {
        try throwIfAborted()
        if replace {
            try await clearFocusedField()
            try await abortableDelay(50)
        }
        try await abortableDelay(80)
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for ch in normalized {
            try throwIfAborted()
            if ch == "\n" {
                try await pressEnterViaCdp()
            } else {
                try await typeCharacterViaCdp(String(ch))
            }
            // NOTE: deliberately NO auto-Enter to "commit" — a blanket
            // Enter-after-type would prematurely submit ordinary forms and navigate
            // away mid-task; submission stays an explicit agent `press`.
            try await abortableDelay(Self.interKeyDelayMs)
        }
    }

    /// Clears the focused field by selecting all of its content and deleting it.
    /// The select-all runs in-page against the focused element so it is
    /// platform-agnostic, then a real CDP Backspace removes the selection.
    private func clearFocusedField() async throws {
        try throwIfAborted()
        _ = try await backend.evaluateViaCdp("""
        (function() {
          var el = document.activeElement;
          if (!el) return false;
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
            try { el.select(); } catch (e) {}
          } else {
            try {
              var range = document.createRange();
              range.selectNodeContents(el);
              var sel = window.getSelection();
              sel.removeAllRanges();
              sel.addRange(range);
            } catch (e) {}
          }
          return true;
        })()
        """)
        try await abortableDelay(50)
        try throwIfAborted()
        try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: [
            "type": .string("keyDown"),
            "key": .string("Backspace"),
            "code": .string("Backspace"),
            "windowsVirtualKeyCode": .number(8)
        ])
        try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: [
            "type": .string("keyUp"),
            "key": .string("Backspace"),
            "code": .string("Backspace"),
            "windowsVirtualKeyCode": .number(8)
        ])
    }

    private func isPrintableAsciiChar(_ char: String) -> Bool {
        guard char.count == 1, let scalar = char.unicodeScalars.first else { return false }
        return scalar.value >= 32 && scalar.value <= 126
    }

    /// Types a single character: a printable ASCII key rides a `keyDown`/`keyUp`
    /// pair carrying its `text`; anything else (e.g. Cyrillic) is committed with
    /// `Input.insertText`.
    private func typeCharacterViaCdp(_ char: String) async throws {
        try throwIfAborted()
        if isPrintableAsciiChar(char) {
            try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: [
                "type": .string("keyDown"),
                "key": .string(char),
                "text": .string(char)
            ])
            try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: [
                "type": .string("keyUp"),
                "key": .string(char)
            ])
        } else {
            try await backend.sendCdpCommand(domain: "Input", command: "insertText", params: [
                "text": .string(char)
            ])
        }
    }

    private func pressEnterViaCdp() async throws {
        try throwIfAborted()
        try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: [
            "type": .string("rawKeyDown"),
            "key": .string("Enter"),
            "code": .string("Enter"),
            "windowsVirtualKeyCode": .number(13)
        ])
        try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: [
            "type": .string("keyUp"),
            "key": .string("Enter"),
            "code": .string("Enter"),
            "windowsVirtualKeyCode": .number(13)
        ])
    }

    /// Resolves a screenshot save target, validating the path is in-sandbox and
    /// the extension is supported.
    public func resolveScreenshotSaveTarget(_ path: String) -> (ok: Bool, resolvedPath: String?, extension: String?, error: String?) {
        guard let resolved = backend.resolveSandboxSavePath(path) else {
            return (false, nil, nil, "saveTo refused: path is outside the sandbox. Pass a path inside the workspace directory. Rejected: \(path)")
        }
        let ext = (resolved as NSString).pathExtension.lowercased()
        let dotExt = ext.isEmpty ? "" : ".\(ext)"
        if isSupportedScreenshotExtension(dotExt) {
            return (true, resolved, dotExt, nil)
        }
        return (false, nil, nil, "saveTo refused: extension must be .png, .jpg, or .jpeg (got \"\(dotExt.isEmpty ? "(none)" : dotExt)\")")
    }

    public func screenshot() async -> AgentActionResult {
        do {
            try throwIfAborted()
            guard let captured = try await backend.captureViewport() else {
                return AgentActionResult(output: "Failed to capture screenshot", isError: true)
            }
            try throwIfAborted()
            let viewport = backend.viewportDimensions()
            let imageSize = ViewportSize(width: captured.imageWidth, height: captured.imageHeight)
            let output: String
            if let viewport = viewport {
                output = "Screenshot captured (\(captured.base64.count) chars base64, viewport: \(viewport.width)x\(viewport.height), image: \(imageSize.width)x\(imageSize.height))"
            } else {
                output = "Screenshot captured (\(captured.base64.count) chars base64, image: \(imageSize.width)x\(imageSize.height))"
            }
            return AgentActionResult(output: output, rawResult: .string(captured.base64), viewport: viewport, imageSize: imageSize)
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Screenshot failed: \(errorMessage(error))", isError: true)
        }
    }

    private func errorMessage(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "\(error)"
    }

    private struct KeyChordDescriptor {
        let key: String
        let code: String
        let keyCode: Int
        let text: String?
        let unmodifiedText: String?
        init(key: String, code: String, keyCode: Int, text: String? = nil, unmodifiedText: String? = nil) {
            self.key = key
            self.code = code
            self.keyCode = keyCode
            self.text = text
            self.unmodifiedText = unmodifiedText
        }
    }

    private static let modifierKeyChordDescriptors: [String: KeyChordDescriptor] = [
        "control": KeyChordDescriptor(key: "Control", code: "ControlLeft", keyCode: 17),
        "shift": KeyChordDescriptor(key: "Shift", code: "ShiftLeft", keyCode: 16),
        "alt": KeyChordDescriptor(key: "Alt", code: "AltLeft", keyCode: 18),
        "meta": KeyChordDescriptor(key: "Meta", code: "MetaLeft", keyCode: 91),
    ]

    private static let specialKeyChordDescriptors: [String: KeyChordDescriptor] = [
        "Enter": KeyChordDescriptor(key: "Enter", code: "Enter", keyCode: 13, text: "\r", unmodifiedText: "\r"),
        "Tab": KeyChordDescriptor(key: "Tab", code: "Tab", keyCode: 9, text: "\t", unmodifiedText: "\t"),
        " ": KeyChordDescriptor(key: " ", code: "Space", keyCode: 32, text: " ", unmodifiedText: " "),
        ".": KeyChordDescriptor(key: ".", code: "Period", keyCode: 190, text: ".", unmodifiedText: "."),
        "@": KeyChordDescriptor(key: "@", code: "Digit2", keyCode: 50, text: "@", unmodifiedText: "@"),
        "Space": KeyChordDescriptor(key: " ", code: "Space", keyCode: 32, text: " ", unmodifiedText: " "),
        "Backspace": KeyChordDescriptor(key: "Backspace", code: "Backspace", keyCode: 8),
        "Delete": KeyChordDescriptor(key: "Delete", code: "Delete", keyCode: 46),
        "Escape": KeyChordDescriptor(key: "Escape", code: "Escape", keyCode: 27),
        "ArrowLeft": KeyChordDescriptor(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37),
        "ArrowUp": KeyChordDescriptor(key: "ArrowUp", code: "ArrowUp", keyCode: 38),
        "ArrowRight": KeyChordDescriptor(key: "ArrowRight", code: "ArrowRight", keyCode: 39),
        "ArrowDown": KeyChordDescriptor(key: "ArrowDown", code: "ArrowDown", keyCode: 40),
        "PageUp": KeyChordDescriptor(key: "PageUp", code: "PageUp", keyCode: 33),
        "PageDown": KeyChordDescriptor(key: "PageDown", code: "PageDown", keyCode: 34),
        "Home": KeyChordDescriptor(key: "Home", code: "Home", keyCode: 36),
        "End": KeyChordDescriptor(key: "End", code: "End", keyCode: 35),
    ]

    private func modifierBit(_ name: String) -> Int {
        switch name.lowercased() {
        case "alt": return 1
        case "control": return 2
        case "meta": return 4
        case "shift": return 8
        default: return 0
        }
    }

    /// Replays one parsed key chord as genuine CDP `Input.dispatchKeyEvent`s rather
    /// than a page-JS helper, so `pressKeys` (e.g. submitting a search with Enter)
    /// actually reaches the page.
    private func emulateKeyChordViaCdp(_ chord: ParsedKeyChord) async throws {
        try throwIfAborted()
        let combinedModifiers = chord.modifiers.reduce(0) { $0 | modifierBit($1) }
        let modifierWithoutShift = (combinedModifiers & ~8) != 0

        let isSpecial = Self.specialKeyChordDescriptors[chord.key] != nil
        let isSingleChar = !isSpecial && chord.key.count == 1
        let descriptor: KeyChordDescriptor
        if let special = Self.specialKeyChordDescriptors[chord.key] {
            descriptor = special
        } else {
            let upper = chord.key.uppercased()
            let keyCode = Int(upper.unicodeScalars.first?.value ?? 0)
            descriptor = KeyChordDescriptor(key: chord.key, code: "Key\(upper)", keyCode: keyCode, text: chord.key, unmodifiedText: chord.key)
        }

        if !chord.modifiers.isEmpty {
            var running = 0
            for modifier in chord.modifiers {
                guard let descr = Self.modifierKeyChordDescriptors[modifier] else { continue }
                running |= modifierBit(modifier)
                try await dispatchKeyEvent("rawKeyDown", descr, modifiers: running)
                try await abortableDelay(3)
            }
        }

        let isDotOrAt = chord.key == "." || chord.key == "@"
        if isSpecial && (descriptor.key == "Enter" || descriptor.key == "Tab" || descriptor.key == " " || isDotOrAt) {
            try await dispatchKeyEvent(
                modifierWithoutShift || !isDotOrAt ? "rawKeyDown" : "keyDown",
                descriptor, modifiers: combinedModifiers)
            if !modifierWithoutShift {
                try await abortableDelay(4)
                try await dispatchCharEvent(descriptor, modifiers: combinedModifiers)
            }
            try await abortableDelay(3)
            try await dispatchKeyEvent("keyUp", descriptor, modifiers: combinedModifiers)
        } else if isSingleChar {
            if modifierWithoutShift {
                try await dispatchKeyEvent("rawKeyDown", descriptor, modifiers: combinedModifiers)
                try await abortableDelay(3)
                try await dispatchKeyEvent("keyUp", descriptor, modifiers: combinedModifiers)
            } else {
                try await dispatchKeyEvent("keyDown", descriptor, modifiers: combinedModifiers)
                try await abortableDelay(3)
                try await dispatchCharEvent(descriptor, modifiers: combinedModifiers, includeCode: false)
                try await abortableDelay(3)
                try await dispatchKeyEvent("keyUp", descriptor, modifiers: combinedModifiers)
            }
        } else {
            try await dispatchKeyEvent("rawKeyDown", descriptor, modifiers: combinedModifiers)
            try await abortableDelay(3)
            try await dispatchKeyEvent("keyUp", descriptor, modifiers: combinedModifiers)
        }

        if !chord.modifiers.isEmpty {
            var running = combinedModifiers
            for modifier in chord.modifiers.reversed() {
                guard let descr = Self.modifierKeyChordDescriptors[modifier] else { continue }
                running &= ~modifierBit(modifier)
                try await dispatchKeyEvent("keyUp", descr, modifiers: running)
                try await abortableDelay(3)
            }
        }
        try await abortableDelay(3)
    }

    private func dispatchKeyEvent(_ type: String, _ descriptor: KeyChordDescriptor, modifiers: Int) async throws {
        try throwIfAborted()
        try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: [
            "type": .string(type),
            "windowsVirtualKeyCode": .number(Double(descriptor.keyCode)),
            "code": .string(descriptor.code),
            "key": .string(descriptor.key),
            "modifiers": .number(Double(modifiers)),
        ])
    }

    private func dispatchCharEvent(_ descriptor: KeyChordDescriptor, modifiers: Int, includeCode: Bool = true) async throws {
        try throwIfAborted()
        var params: [String: JSValue] = [
            "type": .string("char"),
            "text": .string(descriptor.text ?? ""),
            "unmodifiedText": .string(descriptor.unmodifiedText ?? ""),
            "modifiers": .number(Double(modifiers)),
        ]
        if includeCode {
            params["windowsVirtualKeyCode"] = .number(Double(descriptor.keyCode))
        }
        try await backend.sendCdpCommand(domain: "Input", command: "dispatchKeyEvent", params: params)
    }

    // MARK: - select / getText / waitFor (new invocation paths)
    //
    // Unlike click/type/goto/back/pressKeys, these three `window.__aloha` verbs
    // never call `enqueueCdp(...)` — they mutate the DOM (select) or just read it
    // (getText/waitFor), so no host-side `Input.*` dispatch is needed and there is
    // no corresponding `handlePendingRequest` case to wrap. Each installs the
    // in-page runtime (idempotent) then evaluates ONE fixed, Swift-constructed
    // `window.__aloha.<verb>(...)` call over the same `Runtime.evaluate` transport
    // `executeAgentCode` uses (`backend.evaluateViaCdp`) — but never the
    // `buildAgentCodeRunnerScript` free-form authoring wrapper: the call is built
    // here from typed parameters, so a caller can never inject raw JS through it.

    /// Selects an option in the `<select>` element identified by `alohaId`,
    /// matching by visible `text` and/or `index` (mirrors
    /// `window.__aloha.select`'s own precedence — when both are given, `index`
    /// wins). Returns the selected option's label in `output` on success.
    public func selectOptionById(_ alohaId: String, text: String?, index: Int?) async -> AgentActionResult {
        do {
            try throwIfAborted()
            _ = try? await backend.evaluateViaCdp(buildInpageAlohaRuntime())
            try throwIfAborted()
            var selectorFields: [String] = []
            if let index { selectorFields.append("\"index\":\(index)") }
            if let text { selectorFields.append("\"label\":\(jsonStringLiteral(text))") }
            let selectorLiteral = "{\(selectorFields.joined(separator: ","))}"
            let script = "window.__aloha.select(\(jsonStringLiteral(alohaId)), \(selectorLiteral))"
            let value = try await backend.evaluateViaCdp(script)
            try throwIfAborted()
            guard value?.objectMember("success")?.boolValue == true else {
                return AgentActionResult(output: "Select failed on element \(alohaId).", isError: true)
            }
            let selectedLabel = value?.objectMember("selected")?.objectMember("label")?.stringValue ?? ""
            return AgentActionResult(output: "Selected \"\(selectedLabel)\" on element \(alohaId).", rawResult: value)
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "Select failed: \(errorMessage(error))", isError: true)
        }
    }

    /// Reads the visible text (`textContent`) or, for an `<input>`/`<textarea>`,
    /// the current value of the element identified by `alohaId`.
    public func getTextById(_ alohaId: String) async -> AgentActionResult {
        do {
            try throwIfAborted()
            _ = try? await backend.evaluateViaCdp(buildInpageAlohaRuntime())
            try throwIfAborted()
            let script = "window.__aloha.getText(\(jsonStringLiteral(alohaId)))"
            let value = try await backend.evaluateViaCdp(script)
            try throwIfAborted()
            return AgentActionResult(output: value?.stringValue ?? "", rawResult: value)
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "get_text failed: \(errorMessage(error))", isError: true)
        }
    }

    /// The upper bound `waitForSelector` clamps its `timeoutMs` argument to. A
    /// caller-requested timeout above this is silently CLAMPED (not rejected): an
    /// over-eager request still waits the maximum useful budget instead of hard
    /// failing the call outright.
    public static let maxWaitForTimeoutMs: Double = 30_000

    /// Polls the page until `selector` matches an element, or `timeoutMs`
    /// (clamped to ``maxWaitForTimeoutMs``) elapses — wraps
    /// `window.__aloha.waitFor`, which is MutationObserver-based (resolves the
    /// instant a matching element appears) rather than a blind sleep/poll loop.
    /// A timeout is a genuine JS Promise rejection, surfaced here as a thrown
    /// error via `evaluateViaCdp`'s `exceptionDetails` path.
    public func waitForSelector(_ selector: String, timeoutMs: Double) async -> AgentActionResult {
        do {
            try throwIfAborted()
            _ = try? await backend.evaluateViaCdp(buildInpageAlohaRuntime())
            try throwIfAborted()
            let clamped = min(max(timeoutMs, 0), Self.maxWaitForTimeoutMs)
            let script = "window.__aloha.waitFor(\(jsonStringLiteral(selector)), \(Int(clamped)))"
            let value = try await backend.evaluateViaCdp(script)
            try throwIfAborted()
            guard value?.objectMember("success")?.boolValue == true else {
                return AgentActionResult(output: "Timed out waiting for \"\(selector)\".", isError: true)
            }
            return AgentActionResult(output: "Element matching \"\(selector)\" appeared.", rawResult: value)
        } catch {
            if isAbortError(error) {
                return AgentActionResult(output: "Execution stopped", isError: true)
            }
            return AgentActionResult(output: "page_wait_for failed: \(errorMessage(error))", isError: true)
        }
    }
}

private extension JSValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    func objectMember(_ key: String) -> JSValue? {
        if case .object(let members) = self {
            return members.last(where: { $0.0 == key })?.1
        }
        return nil
    }
}
