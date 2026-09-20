import Foundation
import BrowserTools
import ToolABI

// The CLI. One invocation = one command: connect, run exactly one tool call, print,
// disconnect. What it does NOT do any more is take the browser with it.
//
// Element refs (`aloha-id`) live in the page, so they survive exactly as long as the
// browser does. A lane that launched a Chromium per command and killed it on exit could
// therefore never run the second command anyone types — `open` printed refs that were
// already gone by the time `read`/`click` started. So the default lane launches ONE
// browser, records it in `browser.json` under the temp dir, and every later invocation
// attaches to it. It outlives us on purpose; `alohajet quit` is how it ends.
//
//   (default)  the shared browser: launched once, reused, ours to close
//   --launch   one throwaway browser for THIS command, terminated on exit
//   --cdp      someone else's browser: never launched, never terminated, never ours

// MARK: - Exit codes

let exitOK: Int32 = 0
let exitToolError: Int32 = 1
let exitUsage: Int32 = 2
let exitUnreachable: Int32 = 3

struct CLIError: Error {
    let message: String
    let code: Int32
}

// MARK: - Argument parsing

/// Flags that consume the following token. Everything else beginning with `-` is a
/// boolean; `--flag=value` works for any of them.
let valueFlags: Set<String> = [
    "--cdp", "--port", "--tab", "--text", "--index", "--timeout-ms", "--max-chars", "--browser",
    "-p", "--endpoint", "--resume"
]

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]

    func has(_ name: String) -> Bool { flags[name] != nil }
    func value(_ name: String) -> String? { flags[name].flatMap { $0.isEmpty ? nil : $0 } }

    func int(_ name: String) throws -> Int? {
        guard let raw = value(name) else { return nil }
        guard let parsed = Int(raw) else {
            throw CLIError(message: "\(name) expects a number, got \"\(raw)\"", code: exitUsage)
        }
        return parsed
    }

    func required(_ index: Int, _ what: String) throws -> String {
        guard positional.count > index else {
            throw CLIError(message: "missing <\(what)>", code: exitUsage)
        }
        return positional[index]
    }
}

func parseArgs(_ argv: [String]) throws -> Args {
    var args = Args()
    var index = 0
    while index < argv.count {
        let token = argv[index]
        if token == "--" {
            // Everything after `--` is a positional, so `alohajet type <ref> -- -50%` works.
            args.positional.append(contentsOf: argv[(index + 1)...])
            break
        }
        if token.hasPrefix("-"), let equals = token.firstIndex(of: "=") {
            args.flags[String(token[token.startIndex..<equals])] = String(token[token.index(after: equals)...])
        } else if valueFlags.contains(token) {
            index += 1
            guard index < argv.count else {
                throw CLIError(message: "\(token) expects a value", code: exitUsage)
            }
            if argv[index] == "--help" || argv[index] == "-h" {
                args.flags[token] = ""
                args.flags[argv[index]] = ""
            } else {
                args.flags[token] = argv[index]
            }
        } else if token.hasPrefix("-") && token != "-" {
            args.flags[token] = ""
        } else {
            args.positional.append(token)
        }
        index += 1
    }
    return args
}

// MARK: - Help

let commandHelp: [String: String] = [
    "open": """
        alohajet open <url>
          Open a new tab at <url> and print its page as markdown with element refs.
          <url> needs a scheme: https://example.com, not example.com. The new tab is
          now in use; its id works with --tab until the tab or browser closes.
        """,
    "read": """
        alohajet read [--tab <id>]
          Print a tab's page as markdown with element refs. Without --tab: the tab
          left in use by the last command, else one alohajet opened. A tab of
          the user's own is read only when --tab names it.
        """,
    "tabs": """
        alohajet tabs
          List open tabs with their ids and URLs. ● marks the tab in use. A tab
          marked [the user's tab] was open before alohajet attached; close refuses it.
        """,
    "close": """
        alohajet close <id>
          Close a tab by id. Under --cdp or --browser aloha, tabs that were already
          open there belong to the user, and close refuses them.
        """,
    "quit": """
        alohajet quit
          Close the shared browser and delete its profile. Nothing else ends it: it
          outlives each command so the refs one command prints work in the next.
        """,
    "click": """
        alohajet [--tab <id>] click <ref> [--double|--right]
          Click the element with that ref on the tab in use.
        """,
    "type": """
        alohajet [--tab <id>] type <ref> <text> [--submit] [--no-replace]
          Type into an input by ref. --submit presses Enter after; --no-replace
          appends instead of replacing.
        """,
    "select": """
        alohajet [--tab <id>] select <ref> --text <t> | --index <n>
          Pick an option in a <select> by visible text or zero-based index.
        """,
    "text": """
        alohajet [--tab <id>] text <ref>[,<ref>...] [--max-chars <n>]
          Print the visible text (or input value) of up to 20 elements.
        """,
    "goto": """
        alohajet [--tab <id>] goto <url>
          Navigate the tab in use, in place. http and https only.
        """,
    "back": """
        alohajet [--tab <id>] back
          Go back in the tab in use's history.
        """,
    "keys": """
        alohajet [--tab <id>] keys <chord>
          Send a key or chord to whatever has focus, e.g. "Enter", "Control+a".
        """,
    "wait": """
        alohajet [--tab <id>] wait <css-selector> [--timeout-ms <n>]
          Wait until an element matches (timeout 10000 ms by default, 30000 max).
        """,
    "upload": """
        alohajet [--tab <id>] upload <ref> <path> [<path>...]
          Attach files to a file input by ref. Paths must be absolute, on this
          machine. click refuses file inputs: their native dialog cannot be driven.
        """,
    "mcp": """
        alohajet mcp [--endpoint <url>]
          Serve the nine browser tools as an MCP server on stdio. The browser
          options pick the browser, which starts on the first tool call.
          With --endpoint, serve nothing: relay stdio to the MCP server of a running
          Aloha browser at <url>/mcp, for clients that can only run a command, such
          as Claude Desktop. <url> is http to this machine, or https to
          anywhere — a port forward, a second machine. A non-loopback endpoint
          is sent no token unless ALOHAJET_AGENT_TOKEN names one.
        """
]

let usage = """
alohajet — the AlohaJet agent and a scriptable browser, from the command line.

USAGE
  alohajet -p <prompt> [agent options]
  alohajet [browser options] <command> [args]

AGENT
  -p <prompt>             ask the AlohaJet agent in the Aloha browser
  --resume <chat-id>      continue that chat (-p prints its id on stderr)
  --continue              continue the last -p chat (default: a new one)
  --headless              run the app with no window (refused if it has one)
  --endpoint <url>        agent server (default http://127.0.0.1:8765, the
                          local app, launched if needed); http to this machine,
                          https anywhere, and no token leaves this machine
                          unless ALOHAJET_AGENT_TOKEN names one
  --json                  print the whole result as one JSON object
  Until the Terms of Service and Privacy Policy are accepted, -p asks first.

COMMANDS
  open <url>              open a tab and print the page with element refs
  read                    print the tab in use as markdown with element refs
  tabs                    list open tabs
  close <id>              close a tab
  click <ref>             click an element (--double, --right)
  type <ref> <text>       type into an input (--submit, --no-replace)
  select <ref>            choose an option (--text <t> or --index <n>)
  text <ref>[,<ref>...]   print the text of up to 20 elements
  goto <url>, back        navigate the tab in use
  keys <chord>            press a key or chord, e.g. Enter or Control+a
  wait <css>              wait for a CSS selector (--timeout-ms <n>)
  upload <ref> <path>...  attach files to a file input
  quit                    close the shared browser
  mcp                     serve these tools over MCP on stdio
  mcp --endpoint <url>    relay MCP on stdio to the Aloha browser's server

BROWSER OPTIONS (default: one shared Chromium, kept until `alohajet quit`)
  --launch                a throwaway Chromium for this command only
  --no-headless           show the window of a Chromium alohajet launches
  --port <n>              debug port to launch on (default: a free one)
  --cdp <endpoint>        attach to a browser: ws:// URL, port or host:port
  --browser aloha         attach to the Aloha browser, starting it if needed
  --tab <id>              the tab to act on (default: the tab in use)
  --json                  print the raw tool result as JSON

ENVIRONMENT
  ALOHAJET_AGENT_TOKEN    token for -p and mcp --endpoint (default: the app's
                          token file, sent to loopback endpoints only)
  ALOHAJET_BROWSER        Chromium to launch (default: Chrome, else a download)
  ALOHA_BROWSER_APP       the Aloha .app to launch
  ALOHA_CDP_PORT          the Aloha browser's CDP port (default 9222)
  ALOHAJET_NETWORK_LOG    log tabs' requests to this dir; responses unmasked
  ALOHAJET_DEBUG          log protocol chatter to stderr

EXIT CODES
  0 ok, 1 tool or turn failed, 2 usage, 3 browser or app unreachable

`alohajet <command> --help` explains one command; --version prints the version.
"""

// MARK: - Output

func resultJSON(_ result: RawToolResult) -> String {
    var object: [String: WorkflowValue] = [
        "output": .string(result.output),
        "isError": .bool(result.isError ?? false)
    ]
    if let status = result.status { object["status"] = .string(status.rawValue) }
    if let metadata = result.metadata, !metadata.isEmpty { object["metadata"] = .object(metadata) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(WorkflowValue.object(object)),
          let text = String(data: data, encoding: .utf8) else {
        return "{\"isError\":true,\"output\":\"result could not be encoded\"}"
    }
    return text
}

func emit(_ result: RawToolResult, json: Bool) {
    if json {
        writeToStandardOutput(resultJSON(result) + "\n")
    } else if result.isError == true {
        writeToStandardError(result.output + "\n")
    } else {
        writeToStandardOutput(result.output + "\n")
    }
}

// MARK: - Connection

/// The shared browser the default lane reuses, as recorded on disk.
///
/// The old `--attach` read `~/.alohajet/cdp.json` and NOTHING in this package ever wrote
/// it, so the flag could only ever print "no live browser; launching one". This is that
/// file with a writer: the invocation that launches the shared browser records it here,
/// every later invocation attaches to `port`, and `quit` uses `profile`/`stderrLog` to
/// leave nothing behind. Two things changed besides the writer: the path is not
/// `~/.alohajet` (that directory belongs to the Aloha app, and a public tool must not
/// write into another product's home), and `lanes` carries the session state a
/// one-command-per-process CLI otherwise cannot keep — which tab is in use, and which
/// tabs alohajet itself opened — for each browser it talks to, against the
/// `webSocketDebuggerUrl` it was recorded at, which every browser mints fresh per launch.
struct SharedBrowser: Codable {
    var port: Int?
    var profile: String?
    var stderrLog: String?
    var lanes: [String: LaneState]?
}

struct LaneState: Codable, Equatable {
    var endpoint: String?
    var tab: String?
    var openedTabs: [String]?
}

/// `<tmp>/alohajet-<uid>/`: per-user (a shared `/tmp` must not hand one user's debug
/// port to another) and cleared on reboot, like the browser it describes.
let sharedStateDirectory = temporaryDirectory
    .appendingPathComponent("alohajet-\(getuid())", isDirectory: true).path
let sharedStatePath = (sharedStateDirectory as NSString).appendingPathComponent("browser.json")

var laneKey: String?
var lane = LaneState()

func readSharedState() -> SharedBrowser? {
    guard let data = FileManager.default.contents(atPath: sharedStatePath) else { return nil }
    return try? JSONDecoder().decode(SharedBrowser.self, from: data)
}

func writeSharedState(_ state: SharedBrowser) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? FileManager.default.createDirectory(
        atPath: sharedStateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(
        atPath: sharedStatePath, contents: data, attributes: [.posixPermissions: 0o600])
}

func updateSharedState(_ mutate: (inout SharedBrowser) -> Void) {
    var state = readSharedState() ?? SharedBrowser()
    mutate(&state)
    writeSharedState(state)
}

func laneKeyFor(_ args: Args) -> String? {
    if args.value("--browser") == "aloha" { return "aloha" }
    if let endpoint = args.value("--cdp") { return "cdp:\(endpoint)" }
    if args.has("--launch") { return nil }
    return "shared"
}

/// The Chromium the launch lanes run: `ALOHAJET_BROWSER` when set, else a system Chrome,
/// else a Chrome for Testing build downloaded once and cached. The download is the last
/// resort and it is announced, because it is ~150 MB the user did not ask for.
func provisionedExecutablePath() async throws -> String {
    let provisioner = try ChromiumProvisioner(
        browserPath: ProcessInfo.processInfo.environment["ALOHAJET_BROWSER"])
    let manager = FileManager.default
    let willDownload = !(provisioner.browserPath.map(manager.isExecutableFile(atPath:)) ?? false)
        && !manager.isExecutableFile(atPath: provisioner.stagedExecutablePath())
        && !manager.isExecutableFile(atPath: provisioner.systemDefaultPath)
    if willDownload {
        writeToStandardError("""
            alohajet: no browser found at \(provisioner.systemDefaultPath) — downloading \
            Chrome for Testing \(provisioner.buildTable.version) once into \
            \(provisioner.stagedRootDir()). Set ALOHAJET_BROWSER to use your own.\n
            """)
    }
    return try await provisioner.resolveExecutablePath()
}

func connect(_ args: Args) async throws -> BrowserToolSession {
    // Parsed HERE, not inside `launch()`. It used to be read on the launch path only,
    // which had two consequences: `--port frotz` was silently ignored whenever a shared
    // browser was already running, and when it was not, the `CLIError` it throws fell
    // into `launch()`'s catch-all and came back as the struct's `description` —
    // `alohajet: CLIError(message: "--port expects a number, got \"frotz\"", code: 2)` —
    // under exit code 3 (browser unreachable) rather than 2 (usage).
    let requestedPort = try args.int("--port")
    let key = laneKeyFor(args)
    let recorded = key.flatMap { readSharedState()?.lanes?[$0] } ?? LaneState()
    let recordedOwnership = recorded.endpoint.map {
        AgentOwnedTabs(endpoint: $0, ids: Set(recorded.openedTabs ?? []))
    }

    func adopt(_ session: BrowserToolSession) -> BrowserToolSession {
        laneKey = key
        lane = recorded.endpoint == session.webSocketEndpoint ? recorded : LaneState()
        lane.endpoint = session.webSocketEndpoint
        return session
    }

    func launch() async throws -> BrowserToolSession {
        do {
            return try await BrowserToolSession.launch(
                executablePath: try await provisionedExecutablePath(),
                headless: !args.has("--no-headless"),
                port: requestedPort)
        } catch let error as ChromiumProvisionerError {
            throw CLIError(message: error.description, code: exitUnreachable)
        } catch let error as BrowserToolSessionError {
            throw CLIError(message: error.description, code: exitUnreachable)
        } catch {
            throw CLIError(message: "\(error)", code: exitUnreachable)
        }
    }

    func attach(_ endpoint: String) async throws -> BrowserToolSession {
        do {
            if endpoint.hasPrefix("ws://") || endpoint.hasPrefix("wss://") {
                return try await BrowserToolSession.attach(
                    webSocketURL: endpoint, agentOwnedTabs: recordedOwnership)
            }
            if let port = Int(endpoint) {
                return try await BrowserToolSession.attach(
                    port: port, agentOwnedTabs: recordedOwnership)
            }
            let parts = endpoint.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]) else {
                throw CLIError(
                    message: "--cdp expects a ws:// url, a port, or host:port — got \"\(endpoint)\"",
                    code: exitUsage)
            }
            return try await BrowserToolSession.attach(
                host: String(parts[0]), port: port, agentOwnedTabs: recordedOwnership)
        } catch let error as BrowserToolSessionError {
            throw CLIError(message: error.description, code: exitUnreachable)
        }
    }

    switch args.value("--browser") {
    case nil, "chromium":
        break
    case "aloha":
        // The user's own browser, so `ownsBrowser` stays false: its tabs are theirs and
        // `close` refuses them, exactly as under `--cdp`.
        guard args.value("--cdp") == nil else {
            throw CLIError(
                message: "--browser aloha and --cdp name two different browsers; pass one",
                code: exitUsage)
        }
        do {
            let url = try await AlohaBrowser().endpoint()
            return adopt(try await attach(url.absoluteString))
        } catch let error as AlohaBrowserError {
            throw CLIError(message: error.description, code: exitUnreachable)
        }
    case let other?:
        throw CLIError(
            message: "--browser expects chromium or aloha, got \"\(other)\"", code: exitUsage)
    }

    if let endpoint = args.value("--cdp") {
        return adopt(try await attach(endpoint))
    }
    if args.has("--launch") {
        return adopt(try await launch())
    }

    // The shared lane. `ownsBrowser: true` is the whole difference between this and
    // `--cdp`: the tabs in there are ones alohajet opened, so `close` may close them,
    // where a tab in the user's own browser may not be touched.
    // KNOWN CEILING: last writer wins. Two commands starting from cold at the same instant
    // both launch, and one browser ends up unrecorded — the usual pid-file race. Take a
    // lock on the state file if that ever bites; a human typing commands cannot hit it.
    if let browser = readSharedState(), let port = browser.port {
        if let session = try? await BrowserToolSession.attach(
            port: port, ownsBrowser: true, agentOwnedTabs: recordedOwnership) {
            return adopt(session)
        }
        // The recorded browser is not answering, so it is gone — but a browser killed by
        // a signal never got to remove its throwaway profile, and the record about to be
        // overwritten is the last thing that knows where it is. Remove it now or nothing
        // ever will: that is how a machine ends up with seven abandoned profile dirs.
        //
        // Said out loud, because the refs the last command printed die with it and the next
        // command's "no page open" names the wrong cause.
        writeToStandardError(
            "alohajet: the shared browser on port \(port) is gone; starting a new one\n")
        if let profile = browser.profile { try? FileManager.default.removeItem(atPath: profile) }
        if let stderrLog = browser.stderrLog { try? FileManager.default.removeItem(atPath: stderrLog) }
    }
    let session = try await launch()
    guard let launched = session.launchedBrowser else { return adopt(session) }
    updateSharedState {
        $0.port = launched.port
        $0.profile = launched.userDataDir
        $0.stderrLog = launched.stderrLog
    }
    // Hand the browser over to the file we just wrote: `shutdown()` now closes only our
    // socket, and the next invocation attaches to the same Chromium.
    session.releaseBrowser()
    return adopt(session)
}

/// `alohajet quit` — the only thing that ends the shared browser.
///
/// `Browser.close` rather than a signal to the recorded pid: a pid outlives its process
/// and can be reused, and a CLI must never send a signal to a process it cannot prove is
/// the browser it launched. A CDP connection to the recorded port IS that proof.
func quitSharedBrowser() async -> Int32 {
    guard let state = readSharedState(), let port = state.port else {
        writeToStandardOutput("No shared browser is running." + "\n")
        return exitOK
    }
    var closed = false
    if let session = try? await BrowserToolSession.attach(port: port) {
        _ = try? await session.client.send(method: "Browser.close", params: [:])
        await session.shutdown()
        closed = true
        // Chrome unlinks its own lock files as it exits; give it a moment so the
        // profile removal below does not race a live write.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    if let profile = state.profile { try? FileManager.default.removeItem(atPath: profile) }
    if let stderrLog = state.stderrLog { try? FileManager.default.removeItem(atPath: stderrLog) }
    updateSharedState {
        $0.port = nil
        $0.profile = nil
        $0.stderrLog = nil
        $0.lanes?["shared"] = nil
    }
    writeToStandardOutput((closed
        ? "Closed the shared browser on port \(port)."
        : "No browser was listening on port \(port); cleared the stale record.") + "\n")
    return exitOK
}

// MARK: - Commands

/// The tab a page command should act on when `--tab` was not given: the tab in use, then
/// the one the last invocation left in use, then the newest tab alohajet itself opened.
///
/// `nil` when nothing here belongs to alohajet — and NEVER the browser's first http(s)
/// tab, which on `--cdp` and `--browser aloha` is the page the user is reading. A `read`
/// that landed there was a leak and a `goto`/`type` that landed there drove their tab;
/// the caller is told to open one or name one with `--tab` instead.
///
/// KNOWN CEILING: scrapes the `ID:`/`URL:` lines out of `manage_tabs list`'s prose, because
/// the tab list is not exposed any other way. Swap it for a structured accessor if one
/// ever lands on the session.
func resolveTab(_ session: BrowserToolSession, _ explicit: String?) async -> String? {
    if let explicit { return explicit }
    if let active = session.getActiveBrowserTabId() { return active }
    let listing = await session.run("manage_tabs", arguments: ["action": "list"])
    guard listing.isError != true else { return nil }

    var tabs: [(id: String, url: String)] = []
    for line in listing.output.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ID: ") {
            tabs.append((String(trimmed.dropFirst(4)), ""))
        } else if trimmed.hasPrefix("URL: "), !tabs.isEmpty {
            tabs[tabs.count - 1].url = String(trimmed.dropFirst(5))
        }
    }
    let web = tabs.filter { $0.url.hasPrefix("http://") || $0.url.hasPrefix("https://") }
    guard !web.isEmpty else { return nil }
    // The remembered ids are checked against the live list, not trusted: a tab may have
    // been closed since, and a stale id would fail every later command with "not found".
    if let remembered = lane.tab, web.contains(where: { $0.id == remembered }) {
        return remembered
    }
    return (lane.openedTabs ?? []).last { id in web.contains { $0.id == id } }
}

/// The tab id a `manage_tabs` result named, off the metadata channel the tool already
/// fills — no second parse of the prose.
func resultTabId(_ result: RawToolResult) -> String? {
    guard case let .string(id)? = result.metadata?["tabId"], !id.isEmpty else { return nil }
    return id
}

/// Point the page tools at a tab before running one.
///
/// Every invocation is its own session, so nothing carries "the tab in use" over from
/// the last one: without this, a page command lands on whichever tab the browser model
/// considers active — `chrome://newtab` as often as not. One extra round-trip buys a
/// page command that acts on the page the caller means.
func useTab(_ session: BrowserToolSession, _ explicit: String?) async throws {
    if explicit == nil, session.getActiveBrowserTabId() != nil { return }
    guard let tabId = await resolveTab(session, explicit) else {
        throw CLIError(
            message: "no page open — run `alohajet open <url>` first, or `alohajet tabs` and pass --tab <id>",
            code: exitUsage)
    }
    let result = await session.run("manage_tabs", arguments: ["action": "use", "tab_id": tabId])
    if result.isError == true {
        throw CLIError(message: result.output, code: exitToolError)
    }
}

func toolCall(
    _ command: String, _ args: Args, _ session: BrowserToolSession
) async throws -> (String, [String: Any]) {
    switch command {
    case "open":
        return ("manage_tabs", ["action": "open", "url": try args.required(1, "url")])

    case "read":
        guard let tabId = await resolveTab(session, args.value("--tab")) else {
            throw CLIError(
                message: "no page open — run `alohajet open <url>` first, or `alohajet tabs` and pass --tab <id>",
                code: exitUsage)
        }
        return ("manage_tabs", ["action": "read", "tab_id": tabId])

    case "tabs":
        session.setActiveBrowserTab(lane.tab)
        return ("manage_tabs", ["action": "list"])

    case "close":
        return ("manage_tabs", ["action": "close", "tab_id": try args.required(1, "id")])

    case "click":
        try await useTab(session, args.value("--tab"))
        let clickType = args.has("--right") ? "right" : (args.has("--double") ? "double" : "single")
        return ("page_click", ["aloha_id": try args.required(1, "ref"), "click_type": clickType])

    case "type":
        try await useTab(session, args.value("--tab"))
        return ("page_type", [
            "aloha_id": try args.required(1, "ref"),
            "text": try args.required(2, "text"),
            "replace": !args.has("--no-replace"),
            "submit": args.has("--submit")
        ])

    case "select":
        try await useTab(session, args.value("--tab"))
        var arguments: [String: Any] = ["aloha_id": try args.required(1, "ref")]
        if let text = args.value("--text") {
            arguments["text"] = text
        } else if let index = try args.int("--index") {
            arguments["index"] = index
        } else {
            throw CLIError(message: "select needs --text <t> or --index <n>", code: exitUsage)
        }
        return ("page_select", arguments)

    case "text":
        try await useTab(session, args.value("--tab"))
        var arguments: [String: Any] = ["aloha_id": try args.required(1, "ref")]
        if let maxChars = try args.int("--max-chars") { arguments["max_chars"] = maxChars }
        return ("get_text", arguments)

    case "goto":
        try await useTab(session, args.value("--tab"))
        return ("page_navigate", ["action": "goto", "url": try args.required(1, "url")])

    case "back":
        try await useTab(session, args.value("--tab"))
        return ("page_navigate", ["action": "back"])

    case "keys":
        try await useTab(session, args.value("--tab"))
        return ("page_press_keys", ["keys": try args.required(1, "chord")])

    case "wait":
        try await useTab(session, args.value("--tab"))
        var arguments: [String: Any] = ["selector": try args.required(1, "css-selector")]
        if let timeout = try args.int("--timeout-ms") { arguments["timeout_ms"] = timeout }
        return ("page_wait_for", arguments)

    case "upload":
        // Every positional after the ref is a path, so `upload <ref> a.png b.png` is one
        // call. A path that starts with `-` is still a flag to the parser above — pass it
        // after `--`, the same escape `type` documents.
        let ref = try args.required(1, "ref")
        let paths = Array(args.positional.dropFirst(2))
        guard !paths.isEmpty else { throw CLIError(message: "missing <path>", code: exitUsage) }
        try await useTab(session, args.value("--tab"))
        return ("page_upload", ["aloha_id": ref, "paths": paths])

    default:
        throw CLIError(message: "unknown command \"\(command)\". Try --help.", code: exitUsage)
    }
}

// MARK: - Entry point

/// Carry "the tab in use", and which tabs are ours to close, to the next invocation.
/// Nothing else can: each command is its own process, so the session pointer the page
/// tools read is born empty every time and every tab the browser reports looks like the
/// user's. A browser alohajet did not launch has no other way to tell them apart.
func rememberTab(_ command: String, _ args: Args, _ result: RawToolResult, ok: Bool) {
    guard let key = laneKey, ok else { return }
    var next = lane
    switch command {
    case "open":
        if let opened = resultTabId(result) {
            next.openedTabs = Array(((next.openedTabs ?? []).filter { $0 != opened } + [opened]).suffix(64))
            next.tab = opened
        }
    case "close":
        let closed = resultTabId(result) ?? args.positional.dropFirst().first
        next.openedTabs = (next.openedTabs ?? []).filter { $0 != closed }
        if next.tab == closed { next.tab = nil }
    default:
        next.tab = args.value("--tab") ?? resultTabId(result) ?? next.tab
    }
    guard next != lane else { return }
    lane = next
    updateSharedState { $0.lanes = ($0.lanes ?? [:]).merging([key: next]) { _, latest in latest } }
}

func report(_ error: CLIError, json: Bool) {
    if json {
        writeToStandardOutput(resultJSON(RawToolResult(output: error.message, isError: true, status: .error)) + "\n")
    } else {
        writeToStandardError("alohajet: \(error.message)\n")
    }
}

func main() async -> Int32 {
    // `alohajet read | head` closes the pipe under us. The default SIGPIPE disposition
    // kills the process mid-print — before `shutdown()`, which is what terminates a
    // browser we launched. Ignoring it turns that into a failed write we survive.
    signal(SIGPIPE, SIG_IGN)

    let args: Args
    do {
        args = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    } catch let error as CLIError {
        writeToStandardError("alohajet: \(error.message)\n")
        return error.code
    } catch {
        writeToStandardError("alohajet: \(error)\n")
        return exitUsage
    }

    if args.has("--version") {
        writeToStandardOutput("alohajet \(alohajetVersion)\n")
        return exitOK
    }

    let wantsHelp = args.has("--help") || args.has("-h")

    // `-p` is the agent entry, and it takes no command: it is not a tool call, it
    // launches no browser, and it connects to nothing this process owns. Answered
    // here, before `connect`, so a prompt never starts a Chromium it will not use.
    if args.has("-p"), !wantsHelp {
        return await AgentTurn.run(args)
    }

    guard let command = args.positional.first else {
        writeToStandardOutput(usage + "\n")
        return wantsHelp ? exitOK : exitUsage
    }
    if wantsHelp {
        guard let help = commandHelp[command] else {
            writeToStandardError("alohajet: unknown command \"\(command)\"\n")
            return exitUsage
        }
        writeToStandardOutput(help + "\n")
        return exitOK
    }
    let json = args.has("--json")

    // The MCP stdio server takes over here, before anything can reach stdout and before
    // `connect`: it builds its browser on the first `tools/call`, so a host that only
    // lists tools never pays for one. It reads the same connection flags off argv.
    if command == "mcp" {
        // `--endpoint` selects the OTHER product behind this verb: a pipe onto a running
        // browser's own MCP server, serving none of the tools below. `has`, not `value`:
        // an empty `--endpoint=` has still asked for that lane, and answering it with a
        // silent fall-through to a launched Chromium is how a host ends up driving a
        // browser nobody is looking at.
        if args.has("--endpoint") {
            return await MCPRelay.main(args)
        }
        return await MCPServer.main(args)
    }

    // `quit` connects to the recorded browser, not to a new one: it is the command that
    // ENDS the shared lane, so going through `connect` (which launches one when none is
    // running) would be exactly backwards.
    if command == "quit" {
        return await quitSharedBrowser()
    }

    let session: BrowserToolSession
    do {
        session = try await connect(args)
    } catch let error as CLIError {
        report(error, json: json)
        return error.code
    } catch {
        report(CLIError(message: "\(error)", code: exitUnreachable), json: json)
        return exitUnreachable
    }

    // Ctrl-C is the other exit path, and until this line it orphaned the browser and its
    // temp profile — a run must not outlive its launch. Installed only for a browser this
    // command owns: one reached through --cdp is the user's, and the shared browser was
    // released to the commands that come after this one. Neither is ours to reap.
    session.installSignalReaper()

    // One exit path from here down: whatever happens, a browser we launched gets
    // terminated before the process leaves.
    let code: Int32
    do {
        let (tool, arguments) = try await toolCall(command, args, session)
        let result = await session.run(tool, arguments: arguments)
        emit(result, json: json)
        // Every page tool catches its own transport loss into an error RESULT, so a dead
        // browser arrives here indistinguishable from a page that said no. Ask the socket:
        // a wrapper script branches on exit 3 to restart the browser, and exit 1 sends it
        // round the same failing command instead.
        if result.isError != true {
            code = exitOK
        } else if await session.client.isConnected {
            code = exitToolError
        } else {
            let url = URLComponents(string: session.webSocketEndpoint)
            let where_ = [url?.host, url?.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
            writeToStandardError(
                "alohajet: the browser at \(where_.isEmpty ? session.webSocketEndpoint : where_) is gone\n")
            code = exitUnreachable
        }
        rememberTab(command, args, result, ok: code == exitOK)
    } catch let error as CLIError {
        report(error, json: json)
        code = error.code
    } catch {
        report(CLIError(message: "\(error)", code: exitToolError), json: json)
        code = exitToolError
    }
    await session.shutdown()
    return code
}

exit(await main())
