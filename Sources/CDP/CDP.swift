import Foundation
import ToolABI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single CDP target (a tab/page, worker, etc.) as advertised by the
/// browser's `GET /json` discovery listing.
public struct CDPTarget: Sendable, Equatable {
    /// The target id (`id` in the `/json` entry); the same value
    /// `Target.createTarget` returns as `targetId`.
    public let id: String
    /// The target type, e.g. `"page"`, `"background_page"`, `"worker"`.
    public let type: String
    public let title: String
    public let url: String

    public init(id: String, type: String, title: String, url: String) {
        self.id = id
        self.type = type
        self.title = title
        self.url = url
    }
}

// MARK: - CDP events & errors

/// An asynchronous event delivered by a CDP endpoint (a JSON-RPC message that
/// has a `method` but no `id`).
public struct CDPEvent: Sendable, Equatable {
    /// The CDP domain event name, e.g. `"Target.attachedToTarget"`.
    public let method: String
    public let params: JSValue
    /// The session the event belongs to, when using the flat-session model.
    public let sessionId: String?

    public init(method: String, params: JSValue, sessionId: String? = nil) {
        self.method = method
        self.params = params
        self.sessionId = sessionId
    }
}

public enum CDPError: Error, Sendable {
    /// The `/json/version` endpoint did not yield a usable WebSocket URL.
    case discoveryFailed(String)
    case invalidURL(String)
    /// A `send(...)` was issued before `connect()`.
    case notConnected
    case remote(code: Int, message: String)
    /// The socket closed before a pending request was answered.
    case connectionClosed
    case malformedMessage(String)
    case missingField(String)
    /// A command went unanswered past the per-call backstop deadline. The client
    /// drops the orphaned pending continuation and fails the call so
    /// structured-concurrency timeouts and turn-interrupts can unwind, instead of
    /// blocking forever on e.g. an `awaitPromise` evaluate against a wedged page.
    case timeout(method: String)
}

// MARK: - CDPTransport

/// A transport capable of speaking CDP (Chrome DevTools Protocol) over JSON-RPC.
///
/// Any browser application that exposes a CDP endpoint can be driven through a
/// conforming transport, regardless of which app it is.
public protocol CDPTransport: Sendable {
    func connect() async throws

    /// Send a CDP command (e.g. `"Page.navigate"`) and await the `result` object
    /// of its JSON-RPC response.
    func send(method: String, params: [String: JSValue]) async throws -> JSValue

    /// A stream of asynchronous CDP events (JSON-RPC messages with no `id`).
    func events() -> AsyncStream<CDPEvent>
}

public extension CDPTransport {
    func send(method: String) async throws -> JSValue {
        try await send(method: method, params: [:])
    }
}

// MARK: - CDPMessageChannel

/// The raw bidirectional text frame channel the ``CDPClient`` speaks JSON-RPC
/// over. The production channel is a `URLSession` WebSocket; the seam exists so a
/// test can drive the real client's JSON-RPC correlation, flat-session routing,
/// receive loop and event fan-out against a fake browser without a socket.
public protocol CDPMessageChannel: Sendable {
    /// Open the channel (the WebSocket `resume()` equivalent).
    func open() async

    func send(_ text: String) async throws

    /// Await the next inbound text frame. Throws when the channel closes.
    func receive() async throws -> String

    func close() async
}

final class URLSessionWebSocketChannel: CDPMessageChannel, Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        self.task = session.webSocketTask(with: url)
        // CDP responses are unbounded — a Runtime.evaluate result (e.g. a full
        // DOM-tree snapshot from `buildDomTree`), Page.captureScreenshot, or a
        // network body easily exceeds Foundation's 1 MiB default
        // `maximumMessageSize`, which would throw EMSGSIZE ("Message too long")
        // on `receive()` and wedge the connection. 64 MiB so they reassemble.
        self.task.maximumMessageSize = 64 * 1024 * 1024
    }

    func open() async { task.resume() }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let bytes):
            return String(data: bytes, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - CDPClient

/// A `CDPTransport` that connects to a CDP WebSocket endpoint using
/// `URLSession.webSocketTask` (Foundation only, no external dependencies).
///
/// It handles JSON-RPC `id` correlation for command/response, and dispatches
/// asynchronous events to an `AsyncStream<CDPEvent>`. It supports the flat
/// session model (`sessionId` on messages) used by `Target.attachToTarget`
/// with `flatten: true`.
public actor CDPClient: CDPTransport {
    /// The default per-call backstop deadline applied to every `send(...)`.
    ///
    /// Deliberately generous (30s) — longer than the runtime's own 15s read race —
    /// so it only catches a truly stuck call, never a merely slow page.
    public static let defaultCallTimeout: TimeInterval = 30

    private let openChannel: @Sendable () -> CDPMessageChannel

    /// The per-call backstop deadline (seconds). `<= 0` disables the backstop.
    private let callTimeout: TimeInterval

    private var channel: CDPMessageChannel?
    private var nextID: Int = 0
    private var pending: [Int: CheckedContinuation<JSValue, Error>] = [:]

    private var eventContinuations: [UUID: AsyncStream<CDPEvent>.Continuation] = [:]

    private var receiveLoop: Task<Void, Never>?
    private var isClosed = false

    public init(
        webSocketURL: URL,
        session: URLSession = .shared,
        callTimeout: TimeInterval = CDPClient.defaultCallTimeout
    ) {
        #if os(Linux)
        // Foundation's URLSessionWebSocketTask is unusable on Linux (system libcurl
        // lacks WebSocket support), so use the pure-Swift socket WebSocket channel.
        self.openChannel = { LinuxWebSocketChannel(url: webSocketURL) }
        #else
        self.openChannel = { URLSessionWebSocketChannel(url: webSocketURL, session: session) }
        #endif
        self.callTimeout = callTimeout
    }

    public init(
        webSocketURLString: String,
        session: URLSession = .shared,
        callTimeout: TimeInterval = CDPClient.defaultCallTimeout
    ) throws {
        guard let url = URL(string: webSocketURLString) else {
            throw CDPError.invalidURL(webSocketURLString)
        }
        self.init(webSocketURL: url, session: session, callTimeout: callTimeout)
    }

    /// Create a client over an injected message channel: the seam a fake browser
    /// is driven through, exercising the real correlation and routing paths.
    public init(
        channel: @autoclosure @escaping @Sendable () -> CDPMessageChannel,
        callTimeout: TimeInterval = CDPClient.defaultCallTimeout
    ) {
        self.openChannel = channel
        self.callTimeout = callTimeout
    }

    /// Discover the browser-level WebSocket endpoint from `GET
    /// http://host:port/json/version` and create a connected client for it.
    public static func connecting(
        host: String = "127.0.0.1",
        port: Int,
        session: URLSession = .shared
    ) async throws -> CDPClient {
        // `session` stays for the WEBSOCKET channel below; discovery reads the
        // `/json/version` endpoint over a socket instead (see CDPJSONEndpoint.swift).
        let url = try await Self.discoverWebSocketURL(host: host, port: port)
        let client = CDPClient(webSocketURL: url, session: session)
        try await client.connect()
        return client
    }

    /// Resolve the `webSocketDebuggerUrl` advertised by `/json/version`.
    public static func discoverWebSocketURL(
        host: String = "127.0.0.1",
        port: Int
    ) async throws -> URL {
        // Read over a socket, not URLSession — Chrome's header spacing defeats corelibs.
        // See CDPJSONEndpoint.swift.
        let data = try await cdpJSONEndpointGet(host: host, port: port, path: "/json/version")
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let wsString = object["webSocketDebuggerUrl"] as? String,
            let wsURL = URL(string: wsString)
        else {
            throw CDPError.discoveryFailed("No webSocketDebuggerUrl in /json/version response")
        }
        return wsURL
    }

    // MARK: Target discovery

    /// List the browser's live targets by reading `GET http://host:port/json`,
    /// the CDP discovery listing.
    ///
    /// Returns the targets in the order the browser advertised them. An empty or
    /// unreadable `/json` payload yields an empty array — NOT a throw — so a caller
    /// polling a transiently-empty listing is not forced to treat it as a failure.
    public static func listTargets(
        host: String = "127.0.0.1",
        port: Int
    ) async throws -> [CDPTarget] {
        // Read over a socket, not URLSession — see CDPJSONEndpoint.swift.
        let data = try await cdpJSONEndpointGet(host: host, port: port, path: "/json")
        return parseTargets(from: data)
    }

    /// Parse the raw bytes of a `GET /json` discovery listing into `CDPTarget`s.
    /// Kept pure (no I/O) so a stubbed `/json` payload can be parsed directly.
    static func parseTargets(from data: Data) -> [CDPTarget] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return CDPTarget(
                id: id,
                type: entry["type"] as? String ?? "",
                title: entry["title"] as? String ?? "",
                url: entry["url"] as? String ?? ""
            )
        }
    }

    // MARK: CDPTransport

    public func connect() async throws {
        guard channel == nil else { return }
        isClosed = false
        let opened = openChannel()
        channel = opened
        await opened.open()
        startReceiveLoop()
    }

    public func send(method: String, params: [String: JSValue]) async throws -> JSValue {
        guard let channel, !isClosed else {
            throw CDPError.notConnected
        }

        let id = allocateID()
        var message: [String: JSValue] = [
            "id": .number(id),
            "method": .string(method)
        ]
        if !params.isEmpty {
            message["params"] = .object(Array(params))
        }
        let payload = try Self.encode(.object(Array(message)))
        return try await awaitResponse(id: id, method: method, channel: channel, payload: payload)
    }

    /// Send a CDP command addressed to an attached target's flat session.
    ///
    /// In the flat-session model (`Target.attachToTarget` with `flatten: true`),
    /// a command for an attached session must carry its `sessionId` as a
    /// top-level member of the JSON-RPC message — a sibling of `method`/`params`,
    /// not nested inside `params`. This routes such a command to the given
    /// `sessionId` and awaits its result.
    public func send(method: String, params: [String: JSValue], sessionId: String) async throws -> JSValue {
        guard let channel, !isClosed else {
            throw CDPError.notConnected
        }

        let id = allocateID()
        var message: [String: JSValue] = [
            "id": .number(id),
            "method": .string(method),
            "sessionId": .string(sessionId)
        ]
        if !params.isEmpty {
            message["params"] = .object(Array(params))
        }
        let payload = try Self.encode(.object(Array(message)))
        return try await awaitResponse(id: id, method: method, channel: channel, payload: payload)
    }

    /// The shared command/response core for both `send` overloads.
    ///
    /// The awaited response is guarded twice. The cancellation handler is what
    /// lets the runtime's 15s read race and a turn-interrupt unwind a stuck `send`:
    /// without it the orphaned continuation is never resumed, so cancellation
    /// cannot propagate and the call hangs forever. The backstop timeout bounds a
    /// command the browser never answers at all (e.g. an `awaitPromise: true`
    /// evaluate against a wedged page).
    ///
    /// Resume-once safety: every resume path — the response in `handle(message:)`,
    /// the cancel handler, the timeout task, the write-failure path, and
    /// `close()`/`handleReceiveFailure` — funnels through ``removePending(_:)``,
    /// which atomically removes and returns the continuation (or `nil` if it has
    /// already been consumed). Whoever wins the race takes it; every loser sees
    /// `nil` and resumes nothing, so it is resumed exactly once.
    private func awaitResponse(
        id: Int,
        method: String,
        channel: CDPMessageChannel,
        payload: String
    ) async throws -> JSValue {
        // Declared up front (started below) so every exit path can cancel it.
        var timeoutTask: Task<Void, Never>?
        defer { timeoutTask?.cancel() }

        // The response BODY is deliberately summarized (ok/timing only): CDP results
        // can be multi-MB (screenshots, DOM snapshots) and logging them verbatim
        // renders the log unusable. Tool-level results get sizes from the registry.
        await agentLogger.debug("[CDP] → \(method) id=\(id) \(truncateString(payload, limit: 800))")
        let cdpStartedAt = Date()

        do {
            let value: JSValue = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSValue, Error>) in
                    // If the enclosing task was already cancelled before we registered,
                    // fail immediately rather than register a continuation the handler
                    // (which may have already run) can no longer see.
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    pending[id] = continuation

                    Task {
                        do {
                            try await channel.send(payload)
                        } catch {
                            if let waiter = self.removePending(id) {
                                waiter.resume(throwing: error)
                            }
                        }
                    }

                    // Detached so a flood of CDP events on this actor (Network.*
                    // after manage_tabs open) cannot starve the timer.
                    if callTimeout > 0 {
                        let deadlineNanos = UInt64(callTimeout * 1_000_000_000)
                        timeoutTask = Task.detached { [weak self] in
                            try? await Task.sleep(nanoseconds: deadlineNanos)
                            if Task.isCancelled { return }
                            await self?.failPendingWithTimeout(id: id, method: method)
                        }
                    }
                }
            } onCancel: {
                Task { await self.failPendingWithCancellation(id: id) }
            }
            await agentLogger.debug("[CDP] ← \(method) id=\(id) ok ms=\(Int(Date().timeIntervalSince(cdpStartedAt) * 1000))")
            return value
        } catch {
            await agentLogger.debug("[CDP] ✗ \(method) id=\(id) ms=\(Int(Date().timeIntervalSince(cdpStartedAt) * 1000)) error=\(error)")
            throw error
        }
    }

    private func failPendingWithTimeout(id: Int, method: String) {
        if let waiter = removePending(id) {
            waiter.resume(throwing: CDPError.timeout(method: method))
        }
    }

    private func failPendingWithCancellation(id: Int) {
        if let waiter = removePending(id) {
            waiter.resume(throwing: CancellationError())
        }
    }

    public nonisolated func events() -> AsyncStream<CDPEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerEventStream(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeEventStream(id: id) }
            }
        }
    }

    /// Like ``events()`` but registers the stream synchronously before returning,
    /// so no event emitted after this call can be dispatched before the
    /// subscription exists — letting a subscriber that must not miss early events
    /// (e.g. console capture during code execution) subscribe race-free.
    public func subscribeEvents() -> AsyncStream<CDPEvent> {
        subscribeEvents(id: UUID())
    }

    /// ``subscribeEvents()`` under a caller-chosen id, so the subscriber can end it
    /// with ``endEventSubscription(_:)``.
    public func subscribeEvents(id: UUID) -> AsyncStream<CDPEvent> {
        let stream = AsyncStream<CDPEvent> { continuation in
            registerEventStream(id: id, continuation: continuation)
            continuation.onTermination = { _ in
                Task { await self.removeEventStream(id: id) }
            }
        }
        return stream
    }

    /// Ends the subscription registered under `id`. Finishing the stream from this
    /// side delivers every event already dispatched into it before the stream
    /// completes, so a consumer that drains to completion is guaranteed to have seen
    /// them — which waiting a fixed settle delay cannot guarantee on a loaded machine.
    public func endEventSubscription(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)?.finish()
    }

    /// Close the channel and fail any in-flight requests.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveLoop?.cancel()
        receiveLoop = nil
        if let channel { await channel.close() }
        channel = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: CDPError.connectionClosed)
        }
        pending.removeAll()
        for (_, continuation) in eventContinuations {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    // MARK: High-level helpers

    /// Open a new tab/target navigated to `url` and return its `targetId`.
    @discardableResult
    public func openTab(url: String) async throws -> String {
        let result = try await send(
            method: "Target.createTarget",
            params: ["url": .string(url)]
        )
        guard let targetId = result["targetId"]?.stringValue else {
            throw CDPError.missingField("Target.createTarget.targetId")
        }
        return targetId
    }

    /// Attach to a target using the flat-session model and return its
    /// `sessionId`.
    @discardableResult
    public func attachToTarget(targetId: String) async throws -> String {
        let result = try await send(
            method: "Target.attachToTarget",
            params: [
                "targetId": .string(targetId),
                "flatten": .bool(true)
            ]
        )
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw CDPError.missingField("Target.attachToTarget.sessionId")
        }
        return sessionId
    }

    /// Navigate an attached page (identified by its flat-session `sessionId`) to
    /// `url`, returning the resulting `frameId`.
    @discardableResult
    public func navigate(url: String, sessionId: String) async throws -> String {
        let result = try await send(
            method: "Page.navigate",
            params: [
                "url": .string(url),
                "sessionId": .string(sessionId)
            ]
        )
        guard let frameId = result["frameId"]?.stringValue else {
            throw CDPError.missingField("Page.navigate.frameId")
        }
        return frameId
    }

    // MARK: - Internals

    private func allocateID() -> Int {
        nextID += 1
        return nextID
    }

    private func removePending(_ id: Int) -> CheckedContinuation<JSValue, Error>? {
        pending.removeValue(forKey: id)
    }

    private func registerEventStream(
        id: UUID,
        continuation: AsyncStream<CDPEvent>.Continuation
    ) {
        if isClosed {
            continuation.finish()
            return
        }
        eventContinuations[id] = continuation
    }

    private func removeEventStream(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            guard let self else { return }
            while await self.isActive() {
                do {
                    guard let channel = await self.currentChannel() else { break }
                    let message = try await channel.receive()
                    await self.handle(message: message)
                } catch {
                    await self.handleReceiveFailure(error)
                    break
                }
            }
        }
    }

    private func isActive() -> Bool {
        !isClosed && channel != nil
    }

    private func currentChannel() -> CDPMessageChannel? {
        channel
    }

    private func handleReceiveFailure(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true
        channel = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        for (_, continuation) in eventContinuations {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    private func handle(message: String) {
        let data = Data(message.utf8)

        guard
            let object = Self.decode(data),
            case .object = object
        else {
            return
        }

        if let id = object["id"]?.intValue {
            guard let continuation = removePending(id) else { return }
            if let error = object["error"], case .object = error {
                let code = error["code"]?.intValue ?? -1
                let messageText = error["message"]?.stringValue ?? "Unknown CDP error"
                continuation.resume(throwing: CDPError.remote(code: code, message: messageText))
            } else {
                continuation.resume(returning: object["result"] ?? .object([]))
            }
            return
        }

        if let method = object["method"]?.stringValue {
            let params = object["params"] ?? .object([])
            let sessionId = object["sessionId"]?.stringValue
            let event = CDPEvent(method: method, params: params, sessionId: sessionId)
            for (_, continuation) in eventContinuations {
                continuation.yield(event)
            }
        }
    }

    // MARK: Wire (de)serialization

    /// Serialize a `JSValue` to a compact JSON string for the wire, preserving
    /// object key order.
    private static func encode(_ value: JSValue) throws -> String {
        return value.stringify()
    }

    private static func decode(_ data: Data) -> JSValue? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return JSValue.parse(text)
    }
}

/// Launches a local Google Chrome instance with the CDP remote-debugging port
/// enabled, and discovers its WebSocket endpoint.
public struct ChromeLauncher: Sendable {
    /// The conventional path to a system browser executable for the running platform.
    ///
    /// Off Apple there is no single conventional location, so the first existing
    /// candidate wins; when none exist the most common one is returned so the value is
    /// still a reportable path rather than an empty string. Also read by
    /// `ChromiumProvisioner.systemDefaultPath` to decide whether to download a browser.
    public static let defaultExecutablePath: String = {
        #if os(macOS)
        return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        #elseif os(Windows)
        // Conventional install location. Not exercised by this project's CI.
        return #"C:\Program Files\Google\Chrome\Application\chrome.exe"#
        #else
        let candidates = [
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/opt/google/chrome/chrome",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium",
        ]
        let manager = FileManager.default
        return candidates.first { manager.isExecutableFile(atPath: $0) } ?? candidates[0]
        #endif
    }()

    public let executablePath: String

    public init(executablePath: String = ChromeLauncher.defaultExecutablePath) {
        self.executablePath = executablePath
    }

    /// Whether the configured executable exists on disk.
    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    public final class Handle: Sendable {
        public let process: Process
        public let port: Int
        public let userDataDir: URL
        /// Whether this launcher created the `userDataDir` (a throwaway temp profile) and
        /// may delete it on `terminate()`. `false` for a user-provided real profile, which
        /// must be preserved (deleting it would wipe the user's extensions/logins).
        public let ownsUserDataDir: Bool
        /// File the browser's stderr is captured to, outside any profile directory so a
        /// caller-provided real profile is never written into. Read it with
        /// ``stderrTail(maxBytes:)`` BEFORE calling ``terminate()``, which deletes it.
        public let stderrLogURL: URL?

        init(process: Process, port: Int, userDataDir: URL, ownsUserDataDir: Bool, stderrLogURL: URL? = nil) {
            self.process = process
            self.port = port
            self.userDataDir = userDataDir
            self.ownsUserDataDir = ownsUserDataDir
            self.stderrLogURL = stderrLogURL
        }

        /// Stop claiming this profile, so ``ChromeLauncher/reapStaleProfiles()`` leaves it —
        /// and the browser holding it — alone.
        ///
        /// Call it when the browser is DELIBERATELY handed to something that outlives this
        /// process (a shared instance a later invocation attaches to). The reaper's whole
        /// ownership test is the owner file, so removing it is the same statement as "this
        /// is no longer a browser whose run ended". `terminate()` is unaffected.
        public func disownProfile() {
            guard ownsUserDataDir else { return }
            try? FileManager.default.removeItem(
                at: userDataDir.appendingPathComponent(ChromeLauncher.ownerPidFileName))
        }

        /// Chrome explains its own refusals on stderr and nowhere else (e.g. "Failed to
        /// create <profile>/SingletonLock: File exists" when another instance holds the
        /// profile). `nil` when nothing was captured.
        public func stderrTail(maxBytes: Int = 4_096) -> String? {
            guard let stderrLogURL,
                  let data = try? Data(contentsOf: stderrLogURL),
                  !data.isEmpty
            else { return nil }
            let tail = data.count > maxBytes ? data.suffix(maxBytes) : data
            let text = String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        /// Terminate the process and clean up the temporary profile. The exit is
        /// reaped with a bounded escalation (SIGTERM, then SIGINT, then — for our
        /// own launched child only — SIGKILL) so a browser that ignores the gentler
        /// signals cannot wedge the caller on an unbounded `waitUntilExit()`; that
        /// hang is what stalls a long single-process run when a browser is slow to
        /// die. Windows gets the same escalation (`taskkill /F`) so a wedged
        /// Chromium and its profile dir cannot leak there either. Calling this more
        /// than once is safe.
        public func terminate() {
            if process.isRunning {
                process.terminate()
                if !waitForExit(deadline: 3.0) {
                    #if os(macOS) || os(Linux)
                    process.interrupt()
                    if !waitForExit(deadline: 2.0) {
                        // Last resort: hard-kill the child we launched. This only
                        // ever targets this handle's own process id.
                        kill(process.processIdentifier, SIGKILL)
                        _ = waitForExit(deadline: 2.0)
                    }
                    #elseif os(Windows)
                    // Windows has no POSIX signals; `Process.terminate()` posts a
                    // graceful close. If the wedged child still hasn't died, force
                    // it down by PID so a downloaded Chromium cannot leak. This
                    // only ever targets this handle's own process id.
                    hardKillOnWindows(pid: process.processIdentifier)
                    _ = waitForExit(deadline: 2.0)
                    #endif
                }
            }
            // No `process.waitUntilExit()` here. `waitForExit` above already reaped the
            // child on every path that ends with it gone, so on the normal path this call
            // is redundant — and on the one path where it is not (every escalation deadline
            // expired and the process is somehow STILL alive) it is the unbounded wait this
            // method's own documentation promises not to make. It also cannot be reached
            // from the signal reaper without risk: that handler runs on a Dispatch queue
            // while the process is leaving, and a teardown path that can block forever is
            // the defect, not the safety net.
            // Only remove a throwaway temp profile we created — never a user's real
            // Chrome profile, which we merely borrowed.
            if ownsUserDataDir {
                try? FileManager.default.removeItem(at: userDataDir)
            }
            if let stderrLogURL {
                try? FileManager.default.removeItem(at: stderrLogURL)
            }
        }

        #if os(Windows)
        /// The SIGKILL last resort's Windows equivalent, for a child that ignored the
        /// graceful close. Best-effort: `waitForExit` reaps whatever state remains.
        private func hardKillOnWindows(pid: Int32) {
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\taskkill.exe")
            killer.arguments = ["/F", "/PID", String(pid)]
            killer.standardOutput = FileHandle.nullDevice
            killer.standardError = FileHandle.nullDevice
            do {
                try killer.run()
                killer.waitUntilExit()
            } catch {
            }
        }
        #endif

        private func waitForExit(deadline: TimeInterval) -> Bool {
            let limit = Date().addingTimeInterval(deadline)
            while process.isRunning {
                if Date() >= limit { return false }
                Thread.sleep(forTimeInterval: 0.02)
            }
            process.waitUntilExit()
            return true
        }
    }

    // MARK: - Reaping profiles a dead run left behind

    /// The file a throwaway profile carries naming the process that created it. Its
    /// presence is what makes a directory ours to delete; its pid is what says whether
    /// the run that owned it is over.
    public static let ownerPidFileName = "alohajet-owner.pid"

    /// Delete throwaway profiles whose owning process is gone, killing any browser still
    /// holding one.
    ///
    /// The signal handlers a front end installs cover an interrupted run. This covers the
    /// run that never got to handle anything — SIGKILL, a crash, a lost terminal — and
    /// left a headless Chromium and its `alohajet-cdp-<uuid>` profile behind. Two such
    /// browsers, five days old, are what proved this needed a second line of defence.
    ///
    /// OWNERSHIP IS PROVEN TWICE before anything is deleted. The directory must carry the
    /// pid file ``launch(port:headless:userDataDir:profileDirectory:)`` writes — a profile
    /// we did not create has none, and one a concurrent run created a moment ago has none
    /// YET, both of which read as "not ours to touch". And that pid must be gone: `ESRCH`
    /// specifically, since `EPERM` is a live process owned by somebody else.
    ///
    /// The browser is then found by the profile PATH rather than by a recorded pid,
    /// because a pid recorded five days ago may belong to something else entirely by the
    /// time anyone reads it, while `--user-data-dir=<our uuid>` cannot.
    public static func reapStaleProfiles() {
        let manager = FileManager.default
        let tmp = temporaryDirectory
        guard let entries = try? manager.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in entries where name.hasPrefix("alohajet-cdp-") {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            guard let raw = try? String(
                    contentsOf: dir.appendingPathComponent(ownerPidFileName), encoding: .utf8),
                  let owner = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  kill(owner, 0) != 0, errno == ESRCH
            else { continue }
            for pid in pidsHolding(profile: dir.path) { _ = kill(pid, SIGKILL) }
            try? manager.removeItem(at: dir)
        }
        // The stderr log is a SIBLING of the profile, not a file inside it, and its
        // UUID is unrelated to the profile's — so nothing above reaches it, and a run
        // that never got to run `Handle.terminate()` leaves one behind forever. There
        // is no pid to prove ownership with, so age stands in for it: a log nobody has
        // written to in a day belongs to no live run. Deleting one out from under a
        // still-running browser would only cost `stderrTail()`, never the browser.
        let staleBefore = Date().addingTimeInterval(-86_400)
        for name in entries where name.hasPrefix("alohajet-chrome-stderr-") {
            let log = tmp.appendingPathComponent(name)
            guard let modified = try? manager.attributesOfItem(atPath: log.path)[.modificationDate]
                    as? Date, modified < staleBefore
            else { continue }
            try? manager.removeItem(at: log)
        }
    }

    /// The live pids whose argv names `path`: the orphaned browser still holding a dead
    /// run's profile. A `pgrep` that cannot run reports nothing, and the profile is then
    /// removed anyway — that is the outcome that matters.
    ///
    /// ponytail: `pgrep -f` takes a regex and the path is spliced in unescaped, so a
    /// temp directory containing regex metacharacters matches nothing and leaves the
    /// browser. Swap for a `/proc` + `sysctl` scan if that ever shows up.
    private static func pidsHolding(profile path: String) -> [Int32] {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != getpid() }
        #else
        return []
        #endif
    }

    /// Launch Chrome with remote debugging enabled.
    ///
    /// - Parameters:
    ///   - port: The remote-debugging port to bind. A concrete port is
    ///     recommended so `/json/version` can be polled for readiness.
    ///   - userDataDir: When non-`nil`, an existing user-data directory (e.g. the
    ///     user's real Chrome profile, so its extensions and logged-in sessions are
    ///     available) that `terminate()` PRESERVES. When `nil`, a throwaway temp
    ///     profile is created and deleted on `terminate()`.
    ///   - profileDirectory: The `--profile-directory` to open within `userDataDir`;
    ///     ignored when `userDataDir` is `nil`.
    public func launch(
        port: Int,
        headless: Bool = true,
        userDataDir providedDir: URL? = nil,
        profileDirectory: String? = nil
    ) throws -> Handle {
        guard isAvailable else {
            throw CDPError.discoveryFailed("Chrome executable not found at \(executablePath)")
        }

        // A port outside the TCP range cannot be bound and cannot be probed: reject it here
        // rather than launch a browser that will never serve and then poll it for the full
        // discovery timeout. `cdpJSONEndpointGetBlocking` refuses the same values on the
        // attach path, which is where the trap was.
        guard (1...65_535).contains(port) else {
            throw CDPError.discoveryFailed("remote-debugging port \(port) is out of range (1-65535)")
        }

        let ownsUserDataDir = providedDir == nil
        let userDataDir: URL
        if let providedDir {
            userDataDir = providedDir
        } else {
            Self.reapStaleProfiles()
            userDataDir = temporaryDirectory
                .appendingPathComponent("alohajet-cdp-\(UUID().uuidString)", isDirectory: true)
            // 0700: a throwaway profile still accumulates cookies, history and cache for
            // every page the run visits, in a world-readable temp directory.
            try FileManager.default.createDirectory(
                at: userDataDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Written after the directory exists and before the browser starts. The window
            // in which a concurrent run could see a directory of ours that carries no owner
            // is those two syscalls — and a directory with no owner is one the reaper
            // refuses to touch, so the window is safe rather than merely small.
            try? Data("\(getpid())\n".utf8)
                .write(to: userDataDir.appendingPathComponent(Self.ownerPidFileName))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments: [String] = []
        if headless {
            arguments.append("--headless=new")
        }
        arguments.append(contentsOf: [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(userDataDir.path)",
            "--no-first-run",
            "--no-default-browser-check"
        ])
        if ownsUserDataDir {
            // THROWAWAY profile only: use the plaintext password store instead of the macOS
            // Keychain / libsecret so an automated/headless launch never triggers the "Chrome
            // for Testing wants to access Chromium Safe Storage" keychain prompt (which blocks
            // unattended benchmark runs). A caller-PROVIDED profile (e.g. the GUI's clone of
            // the user's real Chrome profile) must NOT get these flags: its Cookies/Login Data
            // are encrypted with the OS-keychain-derived key, and the mock keychain would make
            // every existing login undecryptable — a silent logout.
            arguments.append(contentsOf: [
                "--password-store=basic",
                "--use-mock-keychain",
            ])
        }
        if !ownsUserDataDir, let profileDirectory {
            arguments.append("--profile-directory=\(profileDirectory)")
        }
        // GCE hunters: a Safari-like UA so Cloudflare does not treat Chromium as a
        // bot. Unset or empty keeps Chrome's own default. This is the UA STRING
        // only — Chromium still derives Sec-CH-UA client hints from its real
        // build, so a site reading those is not fooled by this alone.
        if let userAgent = ProcessInfo.processInfo.environment["ALOHAJET_CHROME_USER_AGENT"],
           !userAgent.isEmpty {
            arguments.append("--user-agent=\(userAgent)")
        }
        arguments.append("about:blank")
        process.arguments = arguments
        // stdout stays silenced; stderr is captured to a file, since it is the only place
        // Chrome says why it refused to start. A file, not a `Pipe`: a pipe nobody drains
        // fills its buffer and blocks the browser. Lives outside any profile directory
        // (a caller-provided real profile must not be written into); `terminate()` removes it.
        process.standardOutput = FileHandle.nullDevice
        let stderrLogURL = temporaryDirectory
            .appendingPathComponent("alohajet-chrome-stderr-\(UUID().uuidString).log")
        var capturedStderr: URL?
        // 0600: Chrome's stderr quotes the URLs it fails on.
        if FileManager.default.createFile(
               atPath: stderrLogURL.path, contents: nil,
               attributes: [.posixPermissions: 0o600]),
           let sink = try? FileHandle(forWritingTo: stderrLogURL) {
            process.standardError = sink
            capturedStderr = stderrLogURL
        } else {
            // Capture is a diagnostic aid, never a launch precondition.
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        return Handle(
            process: process, port: port, userDataDir: userDataDir,
            ownsUserDataDir: ownsUserDataDir, stderrLogURL: capturedStderr)
    }

    /// Poll `GET http://host:port/json/version` until the
    /// `webSocketDebuggerUrl` is available (or the timeout elapses).
    ///
    /// Pass `handle` whenever the caller launched the browser itself: a browser that
    /// refused to start is dead, not slow, so this returns as soon as the process is
    /// gone, quoting its exit status and stderr instead of polling out the full timeout.
    /// Omit it when connecting to a browser this process does not own.
    public func discoverWebSocketURL(
        host: String = "127.0.0.1",
        port: Int,
        timeout: TimeInterval = 15,
        pollInterval: TimeInterval = 0.25,
        handle: Handle? = nil
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                return try await CDPClient.discoverWebSocketURL(
                    host: host,
                    port: port
                )
            } catch {
                lastError = error
                // Checked AFTER an attempt, not before: a browser can serve the endpoint
                // and exit between polls, and that attempt's result still counts.
                if let handle, !handle.process.isRunning {
                    throw CDPError.discoveryFailed(browserExitedMessage(handle, host: host, port: port))
                }
                let nanos = UInt64(pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        if let handle, !handle.process.isRunning {
            throw CDPError.discoveryFailed(browserExitedMessage(handle, host: host, port: port))
        }
        throw CDPError.discoveryFailed(
            "Timed out waiting for CDP endpoint on \(host):\(port)"
                + (lastError.map { " (last error: \($0))" } ?? "")
        )
    }

    private func browserExitedMessage(_ handle: Handle, host: String, port: Int) -> String {
        var message = "The browser exited without serving the CDP endpoint on \(host):\(port)"
            + " (exit status \(handle.process.terminationStatus))"
        if let tail = handle.stderrTail() {
            message += ". Browser stderr: \(tail)"
        }
        return message
    }
}
