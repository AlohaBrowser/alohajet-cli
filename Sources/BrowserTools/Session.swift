import Foundation
import Dispatch
import CDP
import ToolABI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// This file is the one place a browser, a CDP client, a tabs service, and the tools
// are wired into something that can execute a call. The CLI and the MCP server are front
// ends over `BrowserToolSession.run`; neither builds any of this itself.

/// The web-extraction defaults this package ships. NOT `.baseline` — that carrier is the
/// A/B control arm (every improvement off), which is the wrong thing for a binary whose
/// whole output is the serialized page.
///
/// - `cleanDom: true` — the serializer's only free win: script/style/svg/hidden subtrees
///   and `class` / `style` / `data-*` / inline `data:` attributes never reach the
///   markdown. Pure local pruning, no extra round-trip. Turning it on is what exposed
///   the `cleanDomTree` root-drop bug fixed in `DomSerializer.swift` — with it ON and
///   that bug live, every page serialized EMPTY.
/// - `batchHints: true` — one appended line on a single-id `get_text` / single-field
///   `page_type`. Costs nothing on the calls that were already batched.
/// - `extractSiteJson: false` — it is the one flag with a SIDE EFFECT: every read
///   `fetch`es `<origin>/products.json?limit=50` from the page. A read tool must not
///   issue unrequested requests to the site by default. Turn it on per session for
///   commerce scraping.
/// - `defaultIncludeScreenshot: false` — a screenshot costs a `Page.captureScreenshot`
///   round-trip plus image tokens on every read. It is a cost choice, not a capability
///   gap: an explicit `include_screenshot: true` comes back on `RawToolResult.images`
///   for any front end that can carry pixels.
public extension AgentWebExtractionOptions {
    nonisolated static let enriched = AgentWebExtractionOptions(
        cleanDom: true,
        extractSiteJson: false,
        defaultIncludeScreenshot: false,
        batchHints: true)
}

public enum BrowserToolSessionError: Error, CustomStringConvertible, Sendable {
    case browserUnavailable(path: String)
    case launchFailed(String)
    case connectFailed(String)
    case noFreePort(String)

    public var description: String {
        switch self {
        case .browserUnavailable(let path):
            return "No browser executable at \(path). Pass executablePath: (or install Chrome/Chromium)."
        case .launchFailed(let detail):
            return "Could not launch the browser: \(detail)"
        case .connectFailed(let detail):
            return "Could not reach the CDP endpoint: \(detail)"
        case .noFreePort(let detail):
            return "Could not reserve a debug port: \(detail)"
        }
    }
}

public struct AgentOwnedTabs: Sendable {
    public let endpoint: String
    public let ids: Set<String>

    public init(endpoint: String, ids: Set<String>) {
        self.endpoint = endpoint
        self.ids = ids
    }

    public func ids(matching endpoint: String) -> Set<String> {
        self.endpoint == endpoint ? ids : []
    }
}

/// A live browser plus the tools wired to drive it.
///
/// Build one with ``launch(executablePath:headless:port:userDataDir:profileDirectory:sessionId:networkLogDirectory:webExtractionOptions:)``
/// (this process owns the browser) or ``attach(webSocketURL:sessionId:networkLogDirectory:webExtractionOptions:)``
/// (someone else's browser — never terminated on ``shutdown()``), then call ``run(_:_:)``.
///
/// It is also the session the tools address: it holds the active-tab pointer the seven
/// page tools resolve through, the network-log directory, and the screenshot buffer. The
/// chat-shaped members of `ExecutorSession` (message groups, agents, persistence) have no
/// meaning outside a chat host and are inert here.
@MainActor public final class BrowserToolSession: ChatModeSession, ExecutorSession {
    public let client: CDPClient
    public let sessionId: String
    public let webExtractionOptions: AgentWebExtractionOptions
    public let webSocketEndpoint: String

    /// The launched browser, or `nil` when this session attached to one it does not own.
    private let browser: ChromeLauncher.Handle?
    /// Whether ``shutdown()`` (and the signal reaper) may terminate ``browser``. Cleared
    /// by ``releaseBrowser()`` when the caller means the browser to outlive this process.
    private var ownsLaunchedBrowser = true
    private let tabsService: TabsService
    private let tools: [String: ExecutorTool]
    private let networkDir: String?

    private var activeTabId: String?
    private var recordingTabIds: [String] = []
    private var callCounter = 0
    private var currentCall: AbortController?
    /// Held for the life of the session: a `DispatchSourceSignal` stops delivering the
    /// moment it is deallocated. See ``installSignalReaper()``.
    private var signalSources: [any DispatchSourceSignal] = []

    private init(
        client: CDPClient,
        browser: ChromeLauncher.Handle?,
        tabsService: TabsService,
        sessionId: String,
        networkDir: String?,
        webExtractionOptions: AgentWebExtractionOptions,
        webSocketEndpoint: String
    ) {
        self.client = client
        self.browser = browser
        self.tabsService = tabsService
        self.sessionId = sessionId
        self.networkDir = networkDir
        self.webExtractionOptions = webExtractionOptions
        self.webSocketEndpoint = webSocketEndpoint
        self.tools = Dictionary(uniqueKeysWithValues: getNativeAgentTools().map { ($0.name, $0) })
        if let networkDir {
            try? FileManager.default.createDirectory(atPath: networkDir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: networkDir)
        }
    }

    /// Launch a browser this session owns and connect to it.
    ///
    /// `port` defaults to a kernel-assigned free port, so concurrent sessions do not
    /// collide. `userDataDir` non-`nil` launches against that existing profile and
    /// preserves it on shutdown; `nil` uses a throwaway profile that is deleted.
    public static func launch(
        executablePath: String = ChromeLauncher.defaultExecutablePath,
        headless: Bool = true,
        port: Int? = nil,
        userDataDir: URL? = nil,
        profileDirectory: String? = nil,
        sessionId: String = "alohajet",
        networkLogDirectory: String? = nil,
        webExtractionOptions: AgentWebExtractionOptions = .enriched
    ) async throws -> BrowserToolSession {
        let launcher = ChromeLauncher(executablePath: executablePath)
        guard launcher.isAvailable else {
            throw BrowserToolSessionError.browserUnavailable(path: executablePath)
        }
        let debugPort = try port ?? freeLocalPort()

        let handle: ChromeLauncher.Handle
        do {
            handle = try launcher.launch(
                port: debugPort, headless: headless,
                userDataDir: userDataDir, profileDirectory: profileDirectory)
        } catch {
            throw BrowserToolSessionError.launchFailed("\(error)")
        }

        let client: CDPClient
        let endpoint: String
        do {
            let wsURL = try await launcher.discoverWebSocketURL(port: debugPort, timeout: 30, handle: handle)
            endpoint = wsURL.absoluteString
            client = CDPClient(webSocketURL: wsURL)
            try await client.connect()
        } catch {
            // The launch succeeded and the connection did not: do not leak a half-open
            // browser (the only teardown on this path).
            handle.terminate()
            throw BrowserToolSessionError.connectFailed("\(error)")
        }
        return await make(
            client: client, browser: handle, sessionId: sessionId,
            networkLogDirectory: networkLogDirectory, webExtractionOptions: webExtractionOptions,
            ownsBrowser: true, endpoint: endpoint, agentOwnedTabs: nil)
    }

    /// Attach to a browser this process did not launch, by its `webSocketDebuggerUrl`.
    /// ``shutdown()`` closes only the socket; the browser is left running.
    ///
    /// `ownsBrowser` says whose tabs the ones already open in there are. `false` (the
    /// default, and the only right answer for a browser the user started) makes every
    /// pre-existing tab the user's, which `manage_tabs close` refuses to touch. Pass
    /// `true` ONLY when this process can show the browser is one alohajet launched —
    /// then its tabs are ours and closable, which is what makes `close` reachable from a
    /// CLI that reconnects to its own browser once per command.
    public static func attach(
        webSocketURL: String,
        sessionId: String = "alohajet",
        networkLogDirectory: String? = nil,
        webExtractionOptions: AgentWebExtractionOptions = .enriched,
        ownsBrowser: Bool = false,
        agentOwnedTabs: AgentOwnedTabs? = nil
    ) async throws -> BrowserToolSession {
        let client: CDPClient
        do {
            client = try CDPClient(webSocketURLString: webSocketURL)
            try await client.connect()
        } catch {
            throw BrowserToolSessionError.connectFailed("\(error)")
        }
        // `connect()` cannot fail for an unreachable endpoint (the channel surfaces
        // failures on first use), so probe with a real call: a stale ws URL (Chrome
        // regenerates the browser GUID every launch) must fail HERE, not inside the
        // first tool call.
        do {
            _ = try await client.send(method: "Browser.getVersion", params: [:])
        } catch {
            await client.close()
            throw BrowserToolSessionError.connectFailed("Browser.getVersion probe failed: \(error)")
        }
        return await make(
            client: client, browser: nil, sessionId: sessionId,
            networkLogDirectory: networkLogDirectory, webExtractionOptions: webExtractionOptions,
            ownsBrowser: ownsBrowser, endpoint: webSocketURL, agentOwnedTabs: agentOwnedTabs)
    }

    /// Attach to a browser already serving a debug port, discovering its websocket URL
    /// from `/json/version` (the `--cdp 9222` shape).
    public static func attach(
        host: String = "127.0.0.1",
        port: Int,
        sessionId: String = "alohajet",
        networkLogDirectory: String? = nil,
        webExtractionOptions: AgentWebExtractionOptions = .enriched,
        ownsBrowser: Bool = false,
        agentOwnedTabs: AgentOwnedTabs? = nil
    ) async throws -> BrowserToolSession {
        let wsURL: URL
        do {
            wsURL = try await CDPClient.discoverWebSocketURL(host: host, port: port)
        } catch {
            throw BrowserToolSessionError.connectFailed("no CDP endpoint on \(host):\(port): \(error)")
        }
        return try await attach(
            webSocketURL: wsURL.absoluteString, sessionId: sessionId,
            networkLogDirectory: networkLogDirectory, webExtractionOptions: webExtractionOptions,
            ownsBrowser: ownsBrowser, agentOwnedTabs: agentOwnedTabs)
    }

    private static func make(
        client: CDPClient,
        browser: ChromeLauncher.Handle?,
        sessionId: String,
        networkLogDirectory: String?,
        webExtractionOptions: AgentWebExtractionOptions,
        ownsBrowser: Bool,
        endpoint: String,
        agentOwnedTabs: AgentOwnedTabs?
    ) async -> BrowserToolSession {
        // Seeded from the browser's live page targets, so an attached session can address
        // the tabs that were already open and a launched one inherits its `about:blank`.
        // Those seeded tabs are the USER'S unless this is a browser alohajet launched —
        // in which case there is no user in there to protect, and the close guard that
        // exists for the user's tabs must not fire on our own `about:blank`.
        let tabsService = await makeCDPBrowserTabsService(
            client: client,
            agentControllerId: sessionId,
            sessionId: sessionId,
            seededTabsAreHuman: !ownsBrowser,
            agentOwnedTabIds: agentOwnedTabs?.ids(matching: endpoint) ?? [])
        let networkDir = networkLogDirectory ?? environmentNetworkLogDirectory(sessionId: sessionId)
        return BrowserToolSession(
            client: client, browser: browser, tabsService: tabsService,
            sessionId: sessionId, networkDir: networkDir,
            webExtractionOptions: webExtractionOptions, webSocketEndpoint: endpoint)
    }

    public var toolNames: [String] { nativeAgentToolNames }
    public var toolSchemas: [NativeToolSchema] { getNativeAgentToolSchemas() }
    public func toolSchema(_ name: String) -> NativeToolSchema? { getNativeAgentToolSchema(name) }

    /// Execute one tool call. Never throws: a thrown tool error comes back as an error
    /// result, because that is what both front ends have to render anyway.
    public func run(_ toolName: String, _ arguments: WorkflowValue?) async -> RawToolResult {
        guard let tool = tools[toolName] else {
            return RawToolResult(
                output: "Unknown tool \"\(toolName)\". Available: \(nativeAgentToolNames.joined(separator: ", ")).",
                isError: true)
        }
        callCounter += 1
        let controller = AbortController()
        currentCall = controller
        defer { if currentCall === controller { currentCall = nil } }

        let context = createToolContext(ToolContextParams(
            sessionId: sessionId,
            toolCallId: "call-\(callCounter)",
            signal: controller.signal,
            mode: .foreground,
            turnId: nil,
            session: self,
            getSandbox: { nil },
            env: [:],
            services: NativeToolServices(
                tabsService: tabsService,
                session: self,
                webExtractionOptions: webExtractionOptions),
            suspend: { _ in nil }))

        do {
            return try await tool.execute(arguments, context)
        } catch {
            return RawToolResult(
                output: "\(toolName) failed: \((error as? AbortSignalError)?.message ?? "\(error)")",
                isError: true,
                status: isAbortError(error) ? .stopped : .error)
        }
    }

    /// `run` over a JSON object as `JSONSerialization` produces it — the shape both a
    /// hand-parsed CLI flag and an MCP `tools/call` payload already have.
    public func run(_ toolName: String, arguments: [String: Any]) async -> RawToolResult {
        await run(toolName, BrowserToolSession.workflowValue(arguments))
    }

    /// Anything a ``WorkflowValue`` cannot represent becomes `.null` rather than failing
    /// the call.
    public static func workflowValue(_ jsonObject: Any) -> WorkflowValue {
        switch jsonObject {
        case let value as String: return .string(value)
        // NSNumber FIRST, and this order is the whole correctness of the function. On
        // Darwin every bridged `Bool` and every `NSNumber` casts to BOTH `Bool` and
        // `NSNumber`: with `case let value as Bool` first, `JSONSerialization`'s `0`
        // arrived as `.bool(false)` and `1` as `.bool(true)`, so `{"index":0}` reached
        // the tool as a boolean and was refused with a message about the wrong argument.
        case let value as NSNumber:
            if isBooleanNumber(value) { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        // Still reachable for a `Bool` that did not bridge (Linux, where `Any`-boxed
        // Swift values are not automatically `NSNumber`).
        case let value as Bool: return .bool(value)
        case let value as [Any]: return .array(value.map(workflowValue))
        case let value as [String: Any]: return .object(value.mapValues(workflowValue))
        default: return .null
        }
    }

    /// Whether an `NSNumber` is carrying a boolean rather than a number.
    ///
    /// There is no portable answer. On Apple platforms a boolean `NSNumber` IS a
    /// `CFBoolean` and the type id says so. corelibs-Foundation vends no `CFGetTypeID`
    /// at all, so off Apple the encoded C type is the discriminator — `"c"` is what
    /// `NSNumber(value: Bool)` reports there.
    private static func isBooleanNumber(_ value: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(value) == CFBooleanGetTypeID()
        #else
        return String(cString: value.objCType) == "c"
        #endif
    }

    /// Aborts the call currently in flight (a wedged page, a Ctrl-C). The tool returns a
    /// `.stopped` result; the session stays usable.
    public func cancel(_ reason: String = "cancelled") {
        currentCall?.abort(reason)
    }

    /// Whether the browser this session launched is still running. Always `true` for an
    /// attached session — this process cannot vouch for a browser it does not own.
    public var isAlive: Bool { browser.map { $0.process.isRunning } ?? true }

    /// Close the CDP socket and, for a LAUNCHED browser we still own, terminate the
    /// process and remove its throwaway profile. An attached — or released — browser is
    /// left alone.
    public func shutdown() async {
        currentCall?.abort("shutdown")
        await client.close()
        if ownsLaunchedBrowser { browser?.terminate() }
    }

    /// Where the browser this session launched can be reached again, or `nil` when it
    /// attached to one it did not launch. `profile` and `stderrLog` are the throwaway
    /// files ``ChromeLauncher/Handle/terminate()`` would have removed, named so a caller
    /// that keeps the browser alive can remove them itself later; a caller-provided real
    /// profile is deliberately NOT named — it is not ours to delete.
    public struct LaunchedBrowser: Sendable {
        public let port: Int
        public let userDataDir: String?
        public let stderrLog: String?
    }

    public var launchedBrowser: LaunchedBrowser? {
        browser.map {
            LaunchedBrowser(
                port: $0.port,
                userDataDir: $0.ownsUserDataDir ? $0.userDataDir.path : nil,
                stderrLog: $0.stderrLogURL?.path)
        }
    }

    /// Keep the launched browser running past this session: neither ``shutdown()`` nor
    /// the signal reaper will terminate it, and its profile is left on disk.
    ///
    /// This is what lets one browser serve many CLI invocations. Element refs live in the
    /// page, so they are worth exactly as much as the browser's remaining lifetime — a
    /// lane that killed the browser on exit could print refs but never use them. The
    /// caller that releases a browser takes on ending it (``launchedBrowser`` says where
    /// it is); nothing else will.
    public func releaseBrowser() {
        ownsLaunchedBrowser = false
        // And out of `ChromeLauncher.reapStaleProfiles()`'s reach: that reaper's whole
        // ownership test is the owner-pid file, and this process — whose pid is in it — is
        // about to exit while the browser deliberately stays. Without this, the next
        // invocation that LAUNCHES one reads a dead owner and kills the shared browser as
        // an orphan.
        browser?.disownProfile()
    }

    /// Reap a browser this session LAUNCHED when the process is interrupted, so a run
    /// cannot outlive its launch.
    ///
    /// Installed only for a launched session. An attached browser is the user's, so
    /// nothing is installed for one and the default disposition — die immediately,
    /// touching nobody's browser — is exactly right. That asymmetry is the whole
    /// design: the cleanup exists for a process the
    /// user can neither see nor close, and it terminates the instance this run started
    /// rather than whatever is running when the signal arrives.
    ///
    /// THE HANDLER IS SYNCHRONOUS AND NEVER TOUCHES THIS ACTOR, which is the whole point:
    /// the interrupt that matters arrives while the main actor is parked inside a CDP
    /// call, so a `Task { await shutdown() }` posted from here would never be scheduled.
    /// Same reason `DiffCDPClient`'s shadow reaper is an `atexit_b` block over immutable
    /// captures rather than a hop back onto an actor. `Handle.terminate()` is nonisolated,
    /// already escalates SIGTERM -> SIGINT -> SIGKILL under a bounded wait, and already
    /// removes the throwaway profile — and only a throwaway one. The CDP socket is not
    /// closed first: the browser it speaks to is being killed and the process is leaving.
    ///
    /// A `DispatchSource` rather than `signal(2)`: its handler runs on a queue, so it may
    /// allocate, spawn and touch the file system, none of which is legal inside a real
    /// signal handler — and `Handle.terminate()` does all three. Same shape as the
    /// shape a long-running CLI's SIGINT teardown needs. The kernel default must be ignored so the source,
    /// and not the default, is what handles the signal.
    ///
    /// `{ @Sendable in }` IS LOAD-BEARING, and is the half of that CLI's handler that got
    /// dropped the first time this was written. This module is main-actor-by-default
    /// (SE-0466, `Package.swift`), so a bare closure literal here is main-actor isolated —
    /// and Dispatch calls it on a global queue, where the isolation check traps BEFORE the
    /// first line of the body runs. Measured, with a breadcrumb on that first line that
    /// never printed: SIGINT killed the process with SIGTRAP and exit 133 and left the
    /// browser running — the exact defect this method exists to fix, reintroduced by the
    /// annotation being left off.
    public func installSignalReaper() {
        guard ownsLaunchedBrowser, let browser, signalSources.isEmpty else { return }
        for number in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in
                browser.terminate()
                // `_exit`, not `exit`, on the belt-and-braces argument only: `exit()` was
                // measured to work here, but it runs `__cxa_finalize` while the main thread
                // is still parked inside a CDP call, and teardown that probes the current
                // executor off the main queue can trap. Nothing in this handler needs an
                // atexit handler to run, so
                // flushing stdio by hand buys the same thing at none of that risk.
                //
                // `stdout`, NOT `nil`. `fflush(NULL)` walks EVERY open `FILE` and takes each
                // one's lock, and `alohajet mcp` always has a thread parked in `readLine`
                // -> `getdelim`, which holds stdin's lock for as long as the host stays
                // quiet. So the handler killed the browser, deleted the profile, and then
                // deadlocked on stdin forever — the process a signalling host waits on
                // never left. Measured: `sample` on the wedged pid showed
                // `installSignalReaper` -> `_fwalk` -> `flockfile` -> `__psynch_mutexwait`.
                // Only stdout is buffered here (the CLI's `print`); everything else in this
                // package writes with `write(2)` and stderr is unbuffered.
                _exit(128 + number)
            }
            signal(number, SIG_IGN)
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - ChatModeSession
    //
    // The tab-addressing state the tools actually read. `manage_tabs use` writes the
    // active-tab pointer here and the seven page tools resolve through it, which is why
    // this is state and not a stub.

    public func sessionNetworkDir() -> String? { networkDir }

    public func registerNetworkRecordingTab(_ tab: TabHandle) {
        if !recordingTabIds.contains(tab.id) { recordingTabIds.append(tab.id) }
    }

    public func unregisterNetworkRecordingTab(_ tabId: String) {
        recordingTabIds.removeAll { $0 == tabId }
    }

    /// The tabs whose network traffic is being written to `<networkDir>/<tabId>.jsonl`.
    public var networkRecordingTabIds: [String] { recordingTabIds }

    public func setActiveBrowserTab(_ tabId: String?) { activeTabId = tabId }
    public func getActiveBrowserTabId() -> String? { activeTabId }
    public func clearActiveBrowserTabIfMatches(_ tabId: String) {
        if activeTabId == tabId { activeTabId = nil }
    }

    // MARK: - ExecutorSession
    //
    // Chat-transcript surface. None of the tools touches it (they never call
    // `context.updateToolResult`), and there is no transcript here to mutate, so every
    // member is inert by design rather than unimplemented.

    public func findToolResult(_ toolCallId: String) -> ToolResultBlockView? { nil }
    public func updateToolCallResult(_ toolCallId: String, _ update: ToolResultUpdate) {}
    public func emitMessagesUpdated(_ messageId: String?) {}
    public func createToolMessageGroup(
        _ call: ToolCall, output: String, status: ToolResultStatus,
        metadata: ToolMetadata?, toolType: String
    ) async -> String { "" }
    public var agents: [String: AgentRecord] { [:] }
    public func detachAgent(_ agentId: String) {}
    public func save() {}
}

/// Where a session writes `<tabId>.jsonl` network logs when no directory was passed
/// explicitly — `nil`, i.e. OFF, unless `ALOHAJET_NETWORK_LOG` says otherwise.
///
/// OFF BY DEFAULT because the log is a wiretap: every request a recorded tab makes,
/// with its headers, its POST bodies and up to 50 KB of each response, written to
/// disk and kept forever. On a logged-in page those headers are `Cookie:` and
/// `Authorization:`. Nobody asked for that by opening a tab, so nobody gets it by
/// opening a tab. The sensitive header values and `postData` are redacted even when
/// it IS on (``NetworkLogWriter``), the file is created 0600 and the directory 0700.
///
/// `ALOHAJET_NETWORK_LOG=<dir>` logs into `<dir>`; `=1`/`true`/`yes`/`on` logs into
/// the old default under the temp directory. Read via `getenv`, matching
/// `ALOHAJET_CREDENTIAL_GUARD`, so a test's `setenv` is observed immediately.
public func environmentNetworkLogDirectory(sessionId: String) -> String? {
    guard let raw = getenv("ALOHAJET_NETWORK_LOG") else { return nil }
    let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    switch value.lowercased() {
    case "", "0", "false", "no", "off": return nil
    case "1", "true", "yes", "on":
        return temporaryDirectory.appendingPathComponent("alohajet/\(sessionId)/network").path
    default: return value
    }
}

/// A kernel-assigned free loopback port. Racy by construction (the port is free when we ask, not when Chrome binds it), which is
/// why it is only the DEFAULT — a caller that needs a fixed port passes one.
func freeLocalPort() throws -> Int {
    #if canImport(Darwin)
    let streamType = SOCK_STREAM
    #else
    let streamType = Int32(SOCK_STREAM.rawValue)
    #endif
    let fd = socket(AF_INET, streamType, 0)
    guard fd >= 0 else { throw BrowserToolSessionError.noFreePort("socket() failed (errno \(errno))") }
    defer { _ = close(fd) }

    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian

    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw BrowserToolSessionError.noFreePort("bind() failed (errno \(errno))") }

    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard named == 0 else { throw BrowserToolSessionError.noFreePort("getsockname() failed (errno \(errno))") }

    let port = Int(UInt16(bigEndian: assigned.sin_port))
    guard port > 0 else { throw BrowserToolSessionError.noFreePort("kernel returned port 0") }
    return port
}

